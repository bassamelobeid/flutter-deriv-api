package BOM::Event::Actions::Track;

use strict;
use warnings;
use Log::Any qw($log);
use BOM::User;
use BOM::User::Client;
use Syntax::Keyword::Try;
use BOM::Event::Services;
use BOM::Platform::Context qw(request);
use Locale::Country qw(code2country);
use List::MoreUtils qw(uniq);
use Time::Moment;
use Date::Utility;

my $loop = IO::Async::Loop->new;
$loop->add(my $services = BOM::Event::Services->new);

# Provides a wrapper instance for communicating with the Segment web API.
# It's a singleton - we don't want to leak memory by creating new ones for every event.
sub _segment {
    return $services->segment();
}

=head2 login

It is triggered for each B<track> event emitted, delivering it to Segment.
Note: As of now it handles B<login> event from Deriv only.

It can be called with the following parameters:

=over

=item * C<loginid> - required. Ligin Id of the user.

=item * C<properties> - Free-form dictionary of event properties, with B<loginid> and B<currency> automatically added here.

=back

=cut

sub login {
    my ($args) = @_;
    my $loginid = $args->{loginid};
    my $properties = $args->{properties} // {};

    unless (_segment->write_key) {
        $log->debugf('Write key was not set.');
        return Future->done;
    }
    return Future->done if request->brand->name ne 'deriv';
    die 'Login tracking triggered without a loginid. Please inform back end team if this continues to occur.' unless $loginid;

    my $client = BOM::User::Client->new({loginid => $loginid})
        or die "Login tracking triggered with an invalid loginid. Please inform back end team if this continues to occur.";
    my @siblings = $client->user->clients(include_disabled => 1);

    # Get list of user currencies
    my @currencies = ();
    my $created_at;
    foreach my $sibling (@siblings) {
        my $account = $sibling->account;
        if ($sibling->is_virtual) {
            # created_at should be the date virtual account has been created
            $created_at = $sibling->date_joined;
            # Skip virtual account currency
            next;
        }
        push @currencies, $account->currency_code if $account && $account->currency_code;
    }

    # We dont have date of birth for virtual account
    my $client_age;
    if ($client->date_of_birth) {
        my ($year, $month, $day) = split('-', $client->date_of_birth);
        my $dob = Time::Moment->new(
            year  => $year,
            month => $month,
            day   => $day
        );
        # If we get delta between now and dob it will be negative so do it vice-versa
        $client_age = $dob->delta_years(Time::Moment->now_utc);
    }
    my $customer = _segment->new_customer(
        user_id => $client->binary_user_id(),
        traits  => {
            # Reserved traits
            address => {
                street      => $client->address_line_1 . " " . $client->address_line_2,
                town        => $client->address_city,
                state       => $client->address_state,
                postal_code => $client->address_postcode,
                country     => Locale::Country::code2country($client->residence),
            },
            age => $client_age,
            #avatar: not_supported,
            birthday => $client->date_of_birth,
            #company: not_supported,
            created_at => Date::Utility->new($created_at)->datetime_iso8601,
            #description: not_supported,
            email      => $client->email,
            first_name => $client->first_name,
            #gender: not_supported,
            #id: not_supported,
            last_name => $client->last_name,
            #name: automatically filled
            phone => $client->phone,
            #title: not_supported,
            #username: not_supported,
            #website: website,

            # Custom traits
            country    => Locale::Country::code2country($client->residence),
            currencies => join(',', sort(uniq(@currencies))),
        });

    my $context = create_context();

    $log->debugf('Send login information for client %s', $client->{loginid});
    return $customer->identify(context => $context)->then(
        sub {
            $customer->track(
                event      => 'login',
                properties => {%$properties},
                context    => $context,
            );
        });
}

=head2 create_context

Dictionary of extra information that provides context about a message.

=cut

sub create_context {
    return {
        locale => request()->language,
        app    => {name => request()->brand->name},
        active => 1
    };
}
1;
