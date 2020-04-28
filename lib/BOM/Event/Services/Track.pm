package BOM::Event::Services::Track;

use strict;
use warnings;
use feature 'state';

use Log::Any qw($log);
use Syntax::Keyword::Try;
use Locale::Country qw(code2country);
use Time::Moment;
use Date::Utility;
use Brands;
use List::Util qw(first any);
use Storable qw(dclone);
use Format::Util::Numbers qw(formatnumber);

use BOM::User;
use BOM::User::Client;
use BOM::Event::Services;
use BOM::Platform::Context qw(request);
use BOM::Platform::Locale qw(get_state_by_id);

my $loop = IO::Async::Loop->new;
$loop->add(my $services = BOM::Event::Services->new);

# Provides a wrapper instance for communicating with the Segment web API.
# It's a singleton - we don't want to leak memory by creating new ones for every event.
sub _segment {
    return $services->segment();
}

=head2 login

It is triggered for each B<login> event emitted, delivering it to Segment.
It can be called with the following named parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

sub login {
    my ($args) = @_;
    my $properties = $args->{properties};

    my $app = request->app // {};
    $properties->{app_name} = $app->{name} // '';

    return track_event(
        event                => 'login',
        loginid              => $args->{loginid},
        properties           => $properties,
        is_identify_required => 1,
    );
}

=head2 signup

It is triggered for each B<signup> event emitted, delivering it to Segment.
It can be called with the following named parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties, with B<loginid> and B<currency> automatically added.

=back

=cut

sub signup {
    my ($args)     = @_;
    my $loginid    = $args->{loginid};
    my $properties = $args->{properties};

    my $client = _validate_params($loginid, 'signup');
    return Future->done unless $client;
    my $customer = _create_customer($client);

    $properties->{loginid} = $loginid;
    # Although we have user profile we also want to have some information on event itself
    my @items = grep { $customer->{$_} } qw(currency landing_company date_joined);
    @{$properties}{@items} = @{$customer}{@items};
    my @traits = grep { $customer->{traits}->{$_} } qw(first_name last_name phone address age country);
    @{$properties}{@traits} = @{$customer->{traits}}{@traits};
    $log->debugf('Track signup event for client %s', $loginid);

    if ($properties->{utm_tags}) {
        @{$customer->{traits}}{keys $properties->{utm_tags}->%*} = values $properties->{utm_tags}->%*;
        delete $properties->{utm_tags};
    }
    return Future->needs_all(_send_identify_request($customer), _send_track_request($customer, $properties, 'signup'));
}

=head2 api_token_created

It is triggered for each B<signup> event emitted, delivering it to Segment.

=cut

sub api_token_created {
    my ($args) = @_;

    return track_event(
        event      => 'api_token_created',
        loginid    => $args->{loginid},
        properties => $args
    );
}

=head2 api_token_deleted

It is triggered for each B<api_token_delete> event emitted, delivering it to Segment.

=cut

sub api_token_deleted {
    my ($args) = @_;

    return track_event(
        event      => 'api_token_deleted',
        loginid    => $args->{loginid},
        properties => $args
    );
}

=head2 account_closure

It is triggered for each B<account_closure> event emitted, delivering the data to Segment.

=cut

sub account_closure {
    my ($args) = @_;

    return track_event(
        event      => 'account_closure',
        loginid    => $args->{loginid},
        properties => $args
    );
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
    my $args       = dclone(shift());
    my $properties = {$args->{properties}->%*};

    die 'mt5 loginid is required' unless $properties->{mt5_login_id};

    $properties->{mt5_loginid} = delete $properties->{mt5_login_id};
    delete $properties->{cs_email};

    return track_event(
        event      => 'mt5_signup',
        loginid    => $args->{loginid},
        properties => $properties
    );
}

=head2 mt5_password_changed

It is triggered for each B<mt5_password_changed> event emitted, delivering it to Segment.
It can be called with the following parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

sub mt5_password_changed {
    my ($args) = @_;
    my $properties = $args->{properties} // {};

    die 'mt5 loginid is required' unless $properties->{mt5_loginid};

    return track_event(
        event      => 'mt5_password_changed',
        loginid    => $args->{loginid},
        properties => $properties
    );
}

=head2 profile_change

It is triggered for each B<changing in user profile> event emitted, delivering it to Segment.
It can be called with the following parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

sub profile_change {
    my ($args) = @_;
    my $loginid = $args->{loginid};
    my $properties = $args->{properties} // {};

    my $client = _validate_params($loginid, 'profile_change');
    return Future->done unless $client;
    my $customer = _create_customer($client);

    $properties->{loginid} = $loginid;
    # Modify some properties to be more readable in segment
    $properties->{updated_fields}->{address_state} = $customer->{traits}->{address}->{state} if $properties->{updated_fields}->{address_state};
    foreach my $field (qw /citizen residence place_of_birth/) {
        $properties->{updated_fields}->{$field} = Locale::Country::code2country($properties->{updated_fields}->{$field})
            if (defined $properties->{updated_fields}->{$field} and $properties->{updated_fields}->{$field} ne '');
    }
    $log->debugf('Track profile_change event for client %s', $loginid);
    return Future->needs_all(_send_identify_request($customer), _send_track_request($customer, $properties, 'profile change'));
}

=head2 transfer_between_accounts

It is triggered for each B<transfer_between_accounts> event emitted, delivering it to Segment.

It is called with the following parameters: 

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties

=back

=cut

sub transfer_between_accounts {
    my ($args) = @_;

    # Deref and ref, So we don't modify the main properties that is passed as an argument
    my $properties = {($args->{properties} // {})->%*};

    $properties->{revenue} = -($properties->{from_amount} // die('required from_account'));
    $properties->{currency} = $properties->{from_currency} // die('required from_currency');
    $properties->{value}    = $properties->{from_amount}   // die('required from_amount');
    $properties->{time} = _time_to_iso_8601($properties->{time} // die('required time'));

    $properties->{fees} = formatnumber('amount', $properties->{from_currency}, $properties->{fees} // 0);

    # Do not send PaymentAgent fields to Segment when it's not a payment agent transfer
    if ($properties->{gateway_code} ne 'payment_agent_transfer') {
        delete $properties->{is_to_account_pa};
        delete $properties->{is_from_account_pa};
    }

    return track_event(
        event      => 'transfer_between_accounts',
        loginid    => $args->{loginid},
        properties => $properties
    );
}

=head2 document_upload

It is triggered for each B<document_upload>, delivering it to Segment.
It can be called with the following parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

sub document_upload {
    my ($args) = @_;
    my $properties = {$args->{properties}->%*};

    delete $properties->{comments};
    delete $properties->{document_id};
    $properties->{upload_date} = _time_to_iso_8601($properties->{upload_date} // die('required time'));
    $properties->{uploaded_manually_by_staff} //= 0;

    return track_event(
        event      => 'document_upload',
        loginid    => $args->{loginid},
        properties => $properties
    );
}

=head2 app_registered

It is triggered for each B<app_registered> event emitted, delivering it to Segment.

=cut

sub app_registered {
    my ($args) = @_;

    return track_event(
        event      => 'app_registered',
        loginid    => $args->{loginid},
        properties => $args
    );

}

=head2 app_updated

It is triggered for each B<app_updated> event emitted, delivering it to Segment.

=cut

sub app_updated {
    my ($args) = @_;

    return track_event(
        event      => 'app_updated',
        loginid    => $args->{loginid},
        properties => $args
    );
}

=head2 app_deleted

It is triggered for each B<app_deleted> event emitted, delivering it to Segment.

=cut

sub app_deleted {
    my ($args) = @_;

    return track_event(
        event      => 'app_deleted',
        loginid    => $args->{loginid},
        properties => $args
    );
}

=head2 set_financial_assessment

It is triggered for each B<set_financial_assessment> event emitted, delivering it to Segment.

=cut

sub set_financial_assessment {
    my ($args) = @_;

    return track_event(
        event      => 'set_financial_assessment',
        loginid    => $args->{loginid},
        properties => $args
    );
}

=head2 track_event

A public method that performs event validation and tracking by Segment B<track> and (if requested) B<identify> API calls.
Takes the following named parameters:

=over 4

=item * C<event> - Name of the event to be emitted.

=item * C<loginid> - Loginid of the client.

=item * C<properties> - event proprties as a hash ref (optional).

=item * C<is_identify_required> - a binary flag determining wether or not make an B<identify> API call (optional)

=item * C<brand> - the brand associated with the event as a L<Brands> object (optional - defaults to request's brand)

=back

=cut

sub track_event {
    my %args = @_;

    my $client = _validate_params($args{loginid}, $args{event}, $args{brand});
    return Future->done unless $client;
    my $customer = _create_customer($client);

    $log->debugf('Tracked %s for client %s', $args{event}, $args{loginid});

    return Future->needs_all(
        _send_track_request($customer, $args{properties}, $args{event}, $args{brand}),
        $args{is_identify_required} ? _send_identify_request($customer, $args{brand}) : Future->done,
    );
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

=head2 _send_identify_request

A private method that makes a Segment B<identify> API call.
It is called with the following parameters:

=over

=item * C<customer> - required. Customer object included traits.

=item *C<brand> - (optional) The request brand as a <Brands> object.

=back

=cut

sub _send_identify_request {
    my ($customer, $brand) = (@_);

    my $context = _create_context($brand);

    return $customer->identify(context => $context);
}

=head2 _send_track_request

A private method that makes a Segment B<track> API call.
It is called with the following parameters:

=over

=item * C<customer> - Customer object included traits.

=item * C<properties> - Free-form dictionary of event properties.

=item * C<event> - The event name that will be sent to the Segment.

=item *C<brand> - (optional) The request brand as a <Brands> object.

=back

=cut

sub _send_track_request {
    my ($customer, $properties, $event, $brand) = (@_);
    my $context = _create_context($brand);

    return $customer->track(
        event      => $event,
        properties => $properties,
        context    => $context,
    );
}

=head2 _create_context

Dictionary of extra information that provides context about a message.
It takes the following args: 

=over

=item *C<brand> - (optional) The request brand as a <Brands> object.

=back

=cut

sub _create_context {
    my $brand = shift // request->brand;
    return {
        locale => request->language,
        app    => {name => $brand->name},
        active => 1
    };
}

=head2 _create_customer

Create customer from client information.
Arguments:

=over

=item * C<client> - required. A L<BOM::User::Client> object representing a client.

=back

=cut

sub _create_customer {
    my ($client) = @_;

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
            #gender     => not_supported for Deriv,
            #id: not_supported,
            last_name => $client->last_name,
            #name: automatically filled
            phone => $client->phone,
            #title: not_supported,
            #username: not_supported,
            #website: website,

            # Custom traits
            country      => Locale::Country::code2country($client->residence),
            currencies   => join(',', sort(keys %currencies)),
            mt5_loginids => join(',', sort($client->user->get_mt5_loginids)),
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

=item * C<event> - required. event name.

=item * C<brand> - optional. brand object.

=back

Returns a L<BOM::User::Client> object constructed by C<loginid> arg.

=cut

sub _validate_params {
    my ($loginid, $event, $brand) = @_;
    $brand //= request->brand;

    unless (_segment->write_key) {
        $log->debugf('Write key was not set.');
        return undef;
    }

    unless ($brand->is_track_enabled) {
        $log->debugf('Event tracking is not enabled for brand %s', $brand->name);
        return undef;
    }

    die "$event tracking triggered without a loginid. Please inform backend team if it continues to occur." unless $loginid;

    my $client = BOM::User::Client->new({loginid => $loginid})
        or die "$event tracking triggered with an invalid loginid $loginid. Please inform backend team if it continues to occur.";

    return $client;
}

1;
