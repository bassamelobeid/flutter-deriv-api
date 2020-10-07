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
use List::Util qw(first any uniq);
use Storable qw(dclone);
use Format::Util::Numbers qw(formatnumber);

use BOM::User;
use BOM::User::Client;
use BOM::Event::Services;
use BOM::Platform::Context qw(request);
use BOM::Platform::Locale qw(get_state_by_id);
use BOM::Database::Model::UserConnect;

my %EVENT_PROPERTIES = (
    identify => [
        qw (address age available_landing_companies avatar birthday company created_at description email first_name gender id landing_companies last_name name phone provider title username website currencies country unsubscribed)
    ],
    login                     => [qw (loginid browser device ip new_signin_activity location app_name)],
    signup                    => [qw (loginid type currency landing_company date_joined first_name last_name phone address age country provider)],
    transfer_between_accounts => [
        qw(revenue currency value from_account to_account from_currency to_currency from_amount to_amount source fees is_from_account_pa
            is_to_account_pa gateway_code remark time id)
    ],
    account_closure   => [qw(loginid closing_reason loginids_disabled  loginids_failed)],
    app_registered    => [qw(loginid name scopes redirect_uri verification_uri app_markup_percentage homepage github appstore googleplay app_id)],
    app_updated       => [qw(loginid name scopes redirect_uri verification_uri app_markup_percentage homepage github appstore googleplay app_id)],
    app_deleted       => [qw(loginid app_id)],
    api_token_created => [qw(loginid name scopes)],
    api_token_deleted => [qw(loginid name scopes)],
    profile_change    => [
        qw(loginid first_name last_name date_of_birth account_opening_reason address_city address_line_1 address_line_2 address_postcode citizen
            residence address_state allow_copiers email_consent phone place_of_birth request_professional_status tax_identification_number tax_residence)
    ],
    mt5_signup           => [qw(loginid account_type language mt5_group mt5_loginid sub_account_type client_first_name type_label mt5_integer_id)],
    mt5_password_changed => [qw(loginid mt5_loginid)],
    document_upload      => [qw(loginid document_type expiration_date file_name id upload_date uploaded_manually_by_staff)],
    set_financial_assessment => [
        qw(loginid education_level employment_industry estimated_worth income_source net_income occupation account_turnover binary_options_trading_experience
            binary_options_trading_frequency cfd_trading_experience cfd_trading_frequency employment_status forex_trading_experience forex_trading_frequency other_instruments_trading_experience
            other_instruments_trading_frequency source_of_wealth)
    ],
    set_self_exclusion => [
        qw(loginid exclude_until max_30day_losses max_30day_turnover max_7day_losses max_7day_turnover max_balance max_deposit
            max_deposit_end_date max_losses max_open_bets max_turnover session_duration_limit timeout_until )
    ],
    p2p_order_created =>
        [qw(loginid user_role order_type  order_id amount currency advertiser_nickname advertiser_user_id client_nickname client_user_id )],
    p2p_order_buyer_has_paid =>
        [qw(loginid user_role order_type  order_id amount currency buyer_user_id buyer_nickname seller_user_id seller_nickname)],
    p2p_order_seller_has_released =>
        [qw(loginid user_role order_type  order_id amount currency buyer_user_id buyer_nickname seller_user_id seller_nickname)],
    p2p_order_cancelled => [qw(loginid  user_role order_type  order_id amount currency buyer_user_id buyer_nickname seller_user_id seller_nickname )],
    p2p_order_expired =>
        [qw(loginid user_role order_type  order_id amount currency buyer_has_confirmed seller_user_id seller_nickname buyer_user_id buyer_nickname)],
    p2p_order_dispute => [
        qw(dispute_reason disputer loginid user_role order_type  order_id amount currency buyer_has_confirmed seller_user_id seller_nickname buyer_user_id buyer_nickname)
    ],
    p2p_order_timeout_refund => [
        qw(loginid user_role order_type  order_id amount currency exchange_rate local_currency seller_user_id seller_nickname buyer_user_id buyer_nickname)
    ],
);

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

    my $user_connect = BOM::Database::Model::UserConnect->new;
    $properties->{provider} = $client->user ? $user_connect->get_connects_by_user_id($client->user->{id})->[0] // 'email' : 'email';

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
    my ($args)     = @_;
    my $loginid    = $args->{loginid};
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

    return Future->needs_all(_send_identify_request($customer),
        _send_track_request($customer, {$properties->{updated_fields}->%*, loginid => $loginid}, 'profile_change'));
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

    $properties->{revenue}  = -($properties->{from_amount} // die('required from_account'));
    $properties->{currency} = $properties->{from_currency} // die('required from_currency');
    $properties->{value}    = $properties->{from_amount} // die('required from_amount');
    $properties->{time}     = _time_to_iso_8601($properties->{time} // die('required time'));

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
        properties => {$args->{params}->%*, loginid => $args->{loginid}},
    );
}

sub p2p_order_created {
    my %args = @_;
    my ($loginid, $order, $parties) = @args{qw(loginid order parties)};

    return track_event(
        event      => 'p2p_order_created',
        loginid    => $parties->{advertiser}->loginid,
        properties => {
            loginid             => $parties->{advertiser}->loginid,
            user_role           => 'advertiser',
            order_type          => $order->{type},
            order_id            => $order->{id},
            amount              => $order->{amount_display},
            currency            => $order->{account_currency},
            advertiser_nickname => $parties->{advertiser_nickname},
            advertiser_user_id  => $parties->{advertiser}->{binary_user_id},
            client_nickname     => $parties->{client_nickname} // '',
            client_user_id      => $parties->{client}->{binary_user_id},
        });
}

sub p2p_order_buyer_has_paid {
    my %args = @_;
    my ($loginid, $order, $parties) = @args{qw(loginid order parties)};

    return track_event(
        event      => 'p2p_order_buyer_has_paid',
        loginid    => $parties->{seller}->loginid,
        properties => _p2p_properties($order, $parties, 'seller'),
    );
}

sub p2p_order_seller_has_released {
    my %args = @_;
    my ($loginid, $order, $parties) = @args{qw(loginid order parties)};

    return track_event(
        event      => 'p2p_order_seller_has_released',
        loginid    => $parties->{buyer}->loginid,
        properties => _p2p_properties($order, $parties, 'buyer'),
    );
}

sub p2p_order_cancelled {
    my %args = @_;
    my ($loginid, $order, $parties) = @args{qw(loginid order parties)};

    return track_event(
        event      => 'p2p_order_cancelled',
        loginid    => $parties->{seller}->loginid,
        properties => _p2p_properties($order, $parties, 'seller'),
    );
}

sub p2p_order_expired {
    my %args = @_;
    my ($loginid, $order, $parties) = @args{qw(loginid order parties)};

    my $buyer_has_confirmed = ($order->{status} eq 'refunded') ? 0 : 1;

    return Future->needs_all(
        track_event(
            event      => 'p2p_order_expired',
            loginid    => $parties->{buyer}->loginid,
            properties => {
                _p2p_properties($order, $parties, 'buyer')->%*,
                buyer_has_confirmed => $buyer_has_confirmed // 0,
            },
        ),
        track_event(
            event      => 'p2p_order_expired',
            loginid    => $parties->{seller}->loginid,
            properties => {
                _p2p_properties($order, $parties, 'seller')->%*,
                buyer_has_confirmed => $buyer_has_confirmed // 0,
            },
        ),
    );
}

=head2 p2p_order_dispute

Sends to segment the disputed order for further email sending or other events. 
Two events should be fired off, one for each party.

=over 4

=item * C<order> The order info

=item * C<parties> The parties involved info

=back

Returns, a Future needing both tracking events.

=cut

sub p2p_order_dispute {
    my %args = @_;
    my ($order, $parties) = @args{qw(order parties)};
    my $brand    = Brands->new(name => 'deriv');
    my $disputer = 'buyer';
    $disputer = 'seller' if $parties->{seller}->loginid eq $order->{dispute_details}->{disputer_loginid};

    return Future->needs_all(
        track_event(
            event      => 'p2p_order_dispute',
            loginid    => $parties->{buyer}->loginid,
            properties => {
                _p2p_properties($order, $parties, 'buyer')->%*,
                dispute_reason => $order->{dispute_details}->{dispute_reason},
                disputer       => $disputer,
            },
            brand => $brand,
        ),
        track_event(
            event      => 'p2p_order_dispute',
            loginid    => $parties->{seller}->loginid,
            properties => {
                _p2p_properties($order, $parties, 'seller')->%*,
                dispute_reason => $order->{dispute_details}->{dispute_reason},
                disputer       => $disputer,
            },
            brand => $brand,
        ),
    );
}

=head2 p2p_order_timeout_refund

Sends to segment the order refunded tracking event for both parties involved. 
It takes the following arguments:

=over 4

=item * C<order> The order info

=item * C<parties> The parties involved info

=back

Returns, a Future needing both tracking events.

=cut

sub p2p_order_timeout_refund {
    my %args = @_;
    my ($order, $parties) = @args{qw(order parties)};
    my $brand = Brands->new(name => 'deriv');

    return Future->needs_all(
        track_event(
            event      => 'p2p_order_timeout_refund',
            loginid    => $parties->{buyer}->loginid,
            properties => _p2p_properties($order, $parties, 'buyer'),
            ,
            brand => $brand,
        ),
        track_event(
            event      => 'p2p_order_timeout_refund',
            loginid    => $parties->{seller}->loginid,
            properties => _p2p_properties($order, $parties, 'seller'),
            ,
            brand => $brand,
        ),
    );
}

=head2 _p2p_properties

Since p2p events have a lot of common properties it makes sense to centralize 
the common fields in a handy sub.
It takes the following arguments:

=over 4

=item * C<order> the p2p order being emitted

=item * C<parties> a hashref containing info for both buyer and seller

=item * C<side> which side this event is for (seller/buyer)

=back

Returns, a hashref with common p2p properties for event tracking.

=cut

sub _p2p_properties {
    my ($order, $parties, $side) = @_;

    return {
        loginid         => $parties->{$side}->loginid,
        user_role       => $side,
        order_type      => $order->{type},
        order_id        => $order->{id},
        exchange_rate   => $order->{rate_display},
        amount          => $order->{amount_display},
        currency        => $order->{account_currency},
        local_currency  => $order->{local_currency},
        buyer_user_id   => $parties->{buyer}->{binary_user_id},
        buyer_nickname  => $parties->{buyer_nickname} // '',
        seller_user_id  => $parties->{seller}->{binary_user_id},
        seller_nickname => $parties->{seller_nickname} // '',
    };
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
    my $customer = _create_customer($client, $args{brand});

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

=item * C<brand> - (optional) The request brand as a <Brands> object.

=back

=cut

sub _send_identify_request {
    my ($customer, $brand) = (@_);

    my $context = _create_context($brand);

    return $customer->identify(context => $context);
}

=head2 _send_track_request

A private method that makes a Segment B<track> API call, just letting valid(known) properties to pass through.
It is called with the following parameters:

=over

=item * C<customer> - Customer object included traits.

=item * C<properties> - Free-form dictionary of event properties.

=item * C<event> - The event name that will be sent to the Segment.

=item * C<brand> - (optional) The request brand as a <Brands> object.

=back

=cut

sub _send_track_request {
    my ($customer, $properties, $event, $brand) = @_;
    my $context = _create_context($brand);

    die "Unknown event <$event> tracking request was triggered by the client $customer->{client_loginid}" unless $EVENT_PROPERTIES{$event};

    # filter invalid or unknown properties out
    my $valid_properties = {map { defined $properties->{$_} ? ($_ => $properties->{$_}) : () } $EVENT_PROPERTIES{$event}->@*};

    return $customer->track(
        event      => $event,
        properties => $valid_properties,
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

=item * C<brand> - (optional) The request brand as a <Brands> object.

=back

=cut

sub _create_customer {
    my ($client, $brand) = @_;
    $brand //= request->brand;

    my @siblings     = $client->user ? $client->user->clients(include_disabled => 1) : ($client);
    my @mt5_loginids = $client->user ? $client->user->get_mt5_loginids               : ();
    my $user_connect = BOM::Database::Model::UserConnect->new;
    my $provider     = $client->user ? $user_connect->get_connects_by_user_id($client->user->{id})->[0] // 'email' : 'email';

    my $country_config              = $brand->countries_instance->countries_list->{$client->residence};
    my $available_landing_companies = join ',' => uniq sort grep { $_ ne 'none' } (
        $country_config->{gaming_company}                   // 'none',
        $country_config->{financial_company}                // 'none',
        $country_config->{mt}->{financial}->{financial}     // 'none',
        $country_config->{mt}->{financial}->{financial_stp} // 'none',
        $country_config->{mt}->{gaming}->{financial}        // 'none',
    );

    # Get list of user currencies & landing companies
    my %currencies        = ();
    my @landing_companies = ();
    my $created_at;

    if (@mt5_loginids) {
        my $mt5_real_accounts = $client->user->mt5_logins_with_group('real');
        foreach my $acc (keys $mt5_real_accounts->%*) {
            $mt5_real_accounts->{$acc} =~ m/\\([a-z]+)(_|$)/;
            push @landing_companies, $1 if $1;
        }
    }

    foreach my $sibling (@siblings) {
        my $account = $sibling->account;
        if ($sibling->is_virtual) {
            # created_at should be the date virtual account has been created
            $created_at = $sibling->date_joined;
            # Skip virtual account currency
            next;
        }
        $currencies{$account->currency_code} = 1 if $account && $account->currency_code;
        push @landing_companies, $sibling->landing_company->short;
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
            country                     => Locale::Country::code2country($client->residence),
            currencies                  => join(',', sort(keys %currencies)),
            mt5_loginids                => join(',', sort(@mt5_loginids)),
            landing_companies           => @landing_companies ? join ',' => uniq sort @landing_companies : 'virtual',
            available_landing_companies => $available_landing_companies,
            provider                    => $provider,

            # subscribe or unsubscribed
            unsubscribed => $client->user->email_consent ? 'false' : 'true',
        });
    # Will use this attributes as properties in some events like signup
    $customer->{currency}        = $client->account ? $client->account->currency_code : '';
    $customer->{landing_company} = $client->landing_company->short // '';
    $customer->{date_joined}     = $client->date_joined // '';
    $customer->{client_loginid}  = $client->loginid;

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
