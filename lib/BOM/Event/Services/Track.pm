package BOM::Event::Services::Track;

use strict;
use warnings;
use Log::Any qw($log);
use BOM::User;
use BOM::User::Client;
use Syntax::Keyword::Try;
use BOM::Event::Services;
use BOM::Platform::Context qw(request);
use Locale::Country qw(code2country);
use Time::Moment;
use Date::Utility;
use BOM::Platform::Locale qw/get_state_by_id/;

my $loop = IO::Async::Loop->new;
$loop->add(my $services = BOM::Event::Services->new);

# Provides a wrapper instance for communicating with the Segment web API.
# It's a singleton - we don't want to leak memory by creating new ones for every event.
sub _segment {
    return $services->segment();
}

my %GENDER_MAPPING = (
    MR   => 'male',
    MRS  => 'female',
    MISS => 'female',
    MS   => 'female'
);

=head2 login

It is triggered for each B<login> event emitted, delivering it to Segment.
It can be called with the following parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

sub login {
    my ($args) = @_;
    my $loginid = $args->{loginid};
    my $properties = $args->{properties} // {};

    return Future->done unless _validate_params($loginid);
    my $customer = _create_customer($loginid);
    $log->debugf('Track login event for client %s', $loginid);
    _identify($customer);
    return _track($customer, $properties, 'login');
}

=head2 signup

It is triggered for each B<signup> event emitted, delivering it to Segment.
It can be called with the following parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties, with B<loginid> and B<currency> automatically added.

=back

=cut

sub signup {
    my ($args) = @_;
    my $loginid = $args->{loginid};
    my $properties = $args->{properties} // {};

    return Future->done unless _validate_params($loginid);
    my $customer = _create_customer($loginid);
    $properties->{loginid} = $loginid;
    # Although we have user profile we also want to have some information on event itself
    map { $properties->{$_} = $customer->{$_}           if $customer->{$_} } qw/currency landing_company date_joined/;
    map { $properties->{$_} = $customer->{traits}->{$_} if $customer->{traits}->{$_} } qw/first_name last_name phone address age country/;
    $log->debugf('Track signup event for client %s', $loginid);
    _identify($customer);
    return _track($customer, $properties, 'signup');
}

=head2 account_closure

It is triggered for each B<account_closure> event emitted, delivering the data to Segment.

=cut

sub account_closure {
    my ($args)     = @_;
    my $loginid    = $args->{loginid};
    my $properties = {%$args};

    return Future->done unless _validate_params($loginid);
    my $customer = _create_customer($loginid);
    $properties->{landing_company} = $customer->{landing_company};

    $log->debugf('Track account_closure event for client %s', $loginid);
    return _track($customer, $properties, 'account_closure');
}

=head2 new_mt5_signup

It is triggered for each B<new mt5 signup> event emitted, delivering it to Segment.
It can be called with the following parameters:
    
=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

sub new_mt5_signup {
    my ($args) = @_;
    my $loginid = $args->{loginid};
    my $properties = $args->{properties} // {};

    delete $properties->{cs_email};
    $properties->{mt5_login_id} = "MT" . $properties->{mt5_login_id};

    return Future->done unless _validate_params($loginid);
    my $customer = _create_customer($loginid);

    $log->debugf('Track new mt5 signup event for client %s', $loginid);
    _identify($customer);
    return _track($customer, $properties, 'mt5 signup');
}

=head2 transfer_between_accounts

It is triggered for each B<transfer_between_accounts> event emitted, delivering it to Segment.
It can be called with the following parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

sub transfer_between_accounts {
    my ($args) = @_;
    my $loginid = $args->{loginid};
    my $properties = $args->{properties} // {};

    return Future->done unless _validate_params($loginid);
    my $customer = _create_customer($loginid);

    $properties->{revenue} = -($properties->{from_amount} // die('required from_account'));
    $properties->{currency} = $properties->{from_currency} // die('required from_currency');
    $properties->{value}    = $properties->{from_amount}   // die('required from_amount');

    $properties->{time} = _time_to_iso_8601($properties->{time} // die('required time'));

    $log->debugf('Track transfer_between_accounts event for client %s', $loginid);

    return _track($customer, $properties, 'transfer_between_accounts');
}

=head2 _time_to_iso_8601 

Convert the format of the database time to iso 8601 time that is sutable for Segment
Arguments:
    
=over

=item * C<time> - required. Database time.

=back

=cut

sub _time_to_iso_8601 {
    my $time = shift;

    my ($y_m_d, $h_m_s) = split(' ', $time);
    my ($year, $month,  $day)    = split('-', $y_m_d);
    my ($hour, $minute, $second) = split(':', $h_m_s);
    return Time::Moment->from_epoch(
        Time::Moment->new(
            year   => $year,
            month  => $month,
            day    => $day,
            hour   => $hour,
            minute => $minute,
            second => $second
        )->epoch
    )->to_string;
}

=head2 _identify

Send identify for each B<customer>.
It can be called with the following parameters:

=over

=item * C<customer> - required. Customer object included traits.

=back

=cut

sub _identify {
    my ($customer) = (@_);
    my $context = _create_context();
    return $customer->identify(context => $context);
}

=head2 _track

Send track for each B<customer>.
It can be called with the following parameters:

=over

=item * C<customer> - required. Customer object included traits.

=item * C<properties> - Free-form dictionary of event properties.

=item * C<event> - required. The event name that will be sent to the Segment.

=back

=cut

sub _track {
    my ($customer, $properties, $event) = (@_);
    my $context = _create_context();
    return $customer->track(
        event      => $event,
        properties => $properties,
        context    => $context,
    );
}

=head2 _create_context

Dictionary of extra information that provides context about a message.

=cut

sub _create_context {
    return {
        locale => request->language,
        app    => {name => request->brand->name},
        active => 1
    };
}

=head2 _create_customer

Create customer from client information.
Arguments:

=over

=item * C<loginid> - required. Login Id of the user.

=back

=cut

sub _create_customer {
    my ($loginid) = @_;

    my $client = BOM::User::Client->new({loginid => $loginid})
        or die "Login tracking triggered with an invalid loginid. Please inform back end team if this continues to occur.";
    my @siblings = $client->user->clients(include_disabled => 1);

    # Get list of user currencies
    my %currencies = ();
    my $created_at;
    foreach my $sibling (@siblings) {
        my $account = $sibling->account;
        if ($sibling->is_virtual) {
            # created_at should be the date virtual account has been created
            $created_at = $sibling->date_joined;
            # Skip virtual account currency
            next;
        }
        $currencies{$account->currency_code} = 1 if $account && $account->currency_code;
    }
    # Check DOB existance as virtual account does not have it
    my $client_age;
    if ($client->date_of_birth) {
        my ($year, $month, $day) = split('-', $client->date_of_birth);
        my $dob = Time::Moment->new(
            year  => $year,
            month => $month,
            day   => $day
        );
        # If we get delta between now and DOB it will be negative so do it vice-versa
        $client_age = $dob->delta_years(Time::Moment->now_utc);
    }

    my $customer = _segment->new_customer(
        user_id => $client->binary_user_id(),
        traits  => {
            # Reserved traits
            address => {
                street      => $client->address_line_1 . " " . $client->address_line_2,
                town        => $client->address_city,
                state       => $client->state ? BOM::Platform::Locale::get_state_by_id($client->state, $client->residence) : '',
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
            gender     => $client->salutation ? $GENDER_MAPPING{uc($client->salutation)} : '',
            #id: not_supported,
            last_name => $client->last_name,
            #name: automatically filled
            phone => $client->phone,
            #title: not_supported,
            #username: not_supported,
            #website: website,

            # Custom traits
            country    => Locale::Country::code2country($client->residence),
            currencies => join(',', sort(keys %currencies)),
        });
    # Will use this attributes as properties in some events like signup
    $customer->{currency} = $client->account ? $client->account->currency_code : '';
    $customer->{landing_company} = $client->landing_company->short // '';
    $customer->{date_joined}     = $client->date_joined            // '';

    return $customer;
}

=head2 _validate_params

Check if required params are valid or not.
Arguments:

=over

=item * C<loginid> - required. Login Id of the user.

=back

=cut

sub _validate_params {
    my ($loginid) = @_;

    unless (_segment->write_key) {
        $log->debugf('Write key was not set.');
        return undef;
    }

    unless (request->brand->is_track_enabled) {
        $log->debugf('Event tracking is not enabled for brand %s', request->brand->name);
        return undef;
    }
    die 'Login tracking triggered without a loginid. Please inform back end team if this continues to occur.' unless $loginid;

    return 1;
}

1;

