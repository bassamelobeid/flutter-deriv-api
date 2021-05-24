package BOM::Event::Actions::User;

use strict;
use warnings;
use utf8;

use List::Util qw(any);
use Text::Unidecode;
use Syntax::Keyword::Try;
use Log::Any qw($log);

use BOM::Event::Services::Track;
use BOM::Platform::Client::Sanctions;
use BOM::User::Client;
use BOM::Platform::Context qw(request localize);
use BOM::Platform::Email qw(send_email);
use BOM::Event::Utility qw(exception_logged);

=head1 NAME

BOM::Event::Actions::User

=head1 DESCRIPTION

Provides handlers for user-related events.

=cut

no indirect;

=head2 login

It is triggered for each B<login> event emitted.
It can be called with the following parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

sub login {
    my @args = @_;

    return BOM::Event::Services::Track::login(@args);
}

sub multiplier_hit_type {
    my @args = @_;

    return BOM::Event::Services::Track::multiplier_hit_type(@args);
}

=head2 profile_change

It is triggered for each B<changing in user profile> event emitted, delivering it to Segment.
It can be called with the following parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties, including all fields that has been updated from Backoffice or set_settings API call.

=back

=cut

sub profile_change {
    my @args   = @_;
    my $params = shift;

    my $loginid = $params->{loginid};

    my $client = eval { BOM::User::Client->new({loginid => $loginid}) } or die 'Could not instantiate client for login ID ' . $loginid;

    # Apply sanctions on profile update
    if (any { exists $params->{properties}->{updated_fields}->{$_} } qw/first_name last_name date_of_birth/) {

        # Grab MT5 accounts and craft a summary
        my $mt5_logins = $client->user->mt5_logins_with_group;
        my @comments;

        push @comments, 'MT5 Accounts', map { sprintf(" - %s %s", $_, $mt5_logins->{$_}) } keys %{$mt5_logins} if scalar keys %{$mt5_logins};
        push @comments, '' if scalar keys %{$mt5_logins};
        push @comments, 'Triggered by profile update';

        BOM::Platform::Client::Sanctions->new({
                client => $client,
                brand  => request()->brand,
            }
        )->check((
            triggered_by => 'Triggered by profile update',
            comments     => join "\n",
            @comments,
        ));

        try {
            BOM::Platform::Event::Emitter::emit(
                'verify_false_profile_info',
                {
                    loginid => $client->loginid,
                    $params->{properties}->{updated_fields}->%{qw/first_name last_name/},
                });
        } catch ($error) {
            $log->warnf('Failed to emit %s event for loginid %s, while processing the profile_change event: %s',
                'verify_false_profile_info', $client->loginid, $error);
        };
    }

    # Trigger auto-remove unwelcome status for MF clients
    $client->update_status_after_auth_fa()
        if any { $params->{properties}->{updated_fields}->{$_} } qw/mifir_id tax_residence tax_identification_number/;

    return BOM::Event::Services::Track::profile_change(@args);
}

=head2 verify_false_profile_info

Verifies a clients profile information and locks the account if false/fake information is detected. 
In that case the client will be marked by a B<cashier_locked> (if already deposited) or B<unwelcome> status (otherwise),
which will be removed automatically after client is authenticated.
It's called with following named arguments:

=over

=item * C<client> - required. A L<BOM::User::Client> object.

=item * C<first_name> - optional. The new value of client's first name.

=item * C<last_name> - optional. The new value of client's last name.

=back

=cut

sub verify_false_profile_info {
    my $args = shift;

    my $loginid = $args->{loginid};
    my $client  = BOM::User::Client->new({loginid => $loginid}) or die 'Could not instantiate client for login ID ' . $loginid;
    my $brand   = request->brand();

    my $vowels_pattern = qr/[aoeiuy]/i;

    my $corporate_pattern = qr/\b(company|ltd.*|co[\.]?|.*club|consult.*|.*limited|holding.*|invest.*|market.*|forex.*|fx.*|.*academy)\b/i;

    # acceptable all-consonant names
    my $exceptions = qr/md/;

    my @fields = (qw/first_name last_name/);

    my ($no_vowels, $corporate_name);

    for my $key (@fields) {
        my $value = $args->{$key};

        next unless $value;

        $no_vowels      |= (lc($value) !~ $exceptions) && (lc(unidecode($value) // '') !~ $vowels_pattern);
        $corporate_name |= (lc($value) =~ $corporate_pattern);
    }

    return undef unless $no_vowels || $corporate_name;

    my $message = $no_vowels ? 'fake profile info - pending POI' : 'potential corporate account - pending POI';

    my ($sibling_locked_for_false_info, $just_locked);
    for my $sibling ($client->user->clients) {
        $sibling_locked_for_false_info = 1 if $sibling->locked_for_false_profile_info;

        next if $sibling->is_virtual || ($sibling->get_poi_status(undef, 0) eq 'verified');

        my $status = $sibling->has_deposits ? 'cashier_locked' : 'unwelcome';
        next if $sibling->status->$status;

        $sibling->status->setnx($status, 'system', $message) unless $sibling->is_virtual;
        $just_locked = 1;
    }

    send_email({
            from          => $brand->emails('no-reply'),
            to            => $client->email,
            subject       => localize("Account verification"),
            template_name => 'authentication_required',
            template_args => {
                l                  => \&localize,
                name               => $client->first_name,
                title              => localize("Account verification"),
                authentication_url => $brand->authentication_url,
                profile_url        => $brand->profile_url,
            },
            use_email_template    => 1,
            email_content_is_html => 1,
            use_event             => 0
        }) if $just_locked && !$sibling_locked_for_false_info;

    return undef;
}

1;
