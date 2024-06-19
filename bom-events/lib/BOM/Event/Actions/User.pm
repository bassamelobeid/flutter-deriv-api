package BOM::Event::Actions::User;

use strict;
use warnings;

use List::Util qw(any);
use Text::Unidecode;
use Syntax::Keyword::Try;
use Log::Any qw($log);
use Text::Trim;

use BOM::Event::Services::Track;
use BOM::Platform::Client::Sanctions;
use BOM::User::Client;
use BOM::Platform::Context qw(request localize);
use BOM::Platform::Event::Emitter;
use BOM::Event::Utility qw(exception_logged);
use BOM::Config::Runtime;

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

=head2 profile_change

It is triggered for each B<changing in user profile> event emitted, delivering it to Segment.
It can be called with the following parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties, including all fields that has been updated from Backoffice or set_settings API call.

=back

=cut

sub profile_change {
    my $params = shift;

    my $loginid = $params->{loginid};

    my $client;
    try {
        $client = BOM::User::Client->new({loginid => $loginid});
    } catch ($e) {
        $log->warnf("Error when get client of login id $loginid. more detail: %s", $e);
    };

    die 'Could not instantiate client for login ID ' . $loginid unless $client;

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

    return 1;
}

=head2 track_profile_change

This is handler for each B<profile_change> event emitted, when handled by track worker.

=cut

sub track_profile_change {
    my $data = shift;

    return BOM::Event::Services::Track::profile_change($data);
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

    my $vowels_regex = qr/[aoeiuy]/i;

    my %regex;
    for my $config (qw/corporate_patterns accepted_consonant_names/) {
        my @patterns = map { (trim $_) || () } BOM::Config::Runtime->instance->app_config->compliance->fake_names->$config->@*;
        # lets see if each pattern starts or ends with a wildcard character
        my @begins_with_wildcard = map { $_ =~ qr/^%/ ? 1 : 0 } @patterns;
        my @ends_with_wildcard   = map { $_ =~ qr/%$/ ? 1 : 0 } @patterns;

        for my $index (0 .. scalar(@patterns) - 1) {
            $patterns[$index] =~ s/^%|%$//g;
            # escape special characters
            $patterns[$index] = "\Q$patterns[$index]\E";
            # put wildcard regular expressions in their original positions
            $patterns[$index] = '.*' . $patterns[$index] if $begins_with_wildcard[$index];
            $patterns[$index] = $patterns[$index] . '.*' if $ends_with_wildcard[$index];
        }
        $regex{$config} = join '|', @patterns;
    }

    my @fields = (qw/first_name last_name/);

    my ($no_vowels, $corporate_name);

    for my $key (@fields) {
        my $value = $args->{$key} or next;

        my $is_accepted_all_consonant = $regex{accepted_consonant_names} && ($value =~ qr/\b($regex{accepted_consonant_names})\b/i);
        $no_vowels |= !$is_accepted_all_consonant && (unidecode($value) !~ $vowels_regex);
        $corporate_name |= ($value =~ qr/\b($regex{corporate_patterns})\b/i) if $regex{corporate_patterns};
    }
    return undef unless $no_vowels || $corporate_name;

    my $message = $no_vowels ? 'fake profile info - pending POI' : 'potential corporate account - pending POI';

    my ($sibling_locked_for_false_info, $just_locked) = (0, 0);
    for my $sibling ($client->user->clients) {
        $sibling_locked_for_false_info = 1 if $sibling->locked_for_false_profile_info;

        next if $sibling->is_virtual || ($sibling->get_poi_status(undef, 0) eq 'verified');

        my $status = $sibling->has_deposits ? 'cashier_locked' : 'unwelcome';
        $sibling->status->setnx($status, 'system', $message);
        $just_locked = 1;
    }

    BOM::Platform::Event::Emitter::emit(
        account_with_false_info_locked => {
            loginid    => $loginid,
            properties => {
                email              => $client->email,
                authentication_url => $brand->authentication_url,
                profile_url        => $brand->profile_url,
            }}) if $just_locked && !$sibling_locked_for_false_info;

    return undef;
}

1;
