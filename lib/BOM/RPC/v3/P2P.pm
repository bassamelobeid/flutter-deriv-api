package BOM::RPC::v3::P2P;

=head1 NAME

BOM::RPC::v3::P2P - peer-to-peer "over-the-counter" payment support

=head1 DESCRIPTION

The P2P cashier is a system which allows buyers and sellers to handle the details
of payments outside our system. It acts as a marketplace for adverts and orders.

=cut

use strict;
use warnings;

no indirect;
use Syntax::Keyword::Try;
use JSON::MaybeUTF8 qw(:v1);
use DataDog::DogStatsd::Helper qw(stats_inc);
use List::Util qw (any);

use BOM::User::Client;
use BOM::Platform::Context qw (localize request);
use BOM::Config;
use BOM::Config::Runtime;
use BOM::User;
use ExchangeRates::CurrencyConverter qw(convert_currency);
use Format::Util::Numbers qw/financialrounding formatnumber/;

use BOM::RPC::Registry '-dsl';

use Log::Any qw($log);

# Currently all functionality is restricted to users with
# valid accounts. There's little harm in allowing a list
# of orders or adverts, but also no value to us in doing so.
requires_auth();

use constant RESTRICTED_CLIENT_STATUSES => [qw(
        unwelcome
        cashier_locked
        withdrawal_locked
        no_withdrawal_or_trading
        )];

# Standard error codes for any P2P calls.
our %ERROR_MAP = do {
    # `make i18n` wants to see literal strings in `localize()` calls to decide
    # what to translate. We temporarily provide a no-op version so we can
    # populate our static definitions. We'll then run `localize` *again* on
    # each item when we want to send to a client.
    ## no critic(TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'redefine';

    local *localize = sub { die 'you probably wanted an arrayref for this localize() call' if @_ > 1; shift };
    (
        # System or country limitations
        P2PDisabled          => localize('The P2P cashier is currently disabled.'),
        RestrictedCountry    => localize('This country is not enabled for P2P cashier functionality.'),
        RestrictedCurrency   => localize('This currency is not enabled for P2P cashier functionality.'),
        UnavailableOnVirtual => localize('P2P cashier functionality is not available on demo accounts.'),
        NoCountry            => localize('You need to set your residence in order to use this feature.'),
        NoLocalCurrency      => localize('We are unable to determine the local currency for your country.'),

        # Client status
        NotLoggedIn      => localize('You are not logged in.'),
        NoCurrency       => localize('You have not yet selected a currency for your account.'),
        PermissionDenied => localize('You do not have permission for this action.'),
        NotRegistered    => localize('You are not yet registered as a P2P advertiser.'),

        # Invalid data
        NotFound                  => localize('Not found.'),
        MinimumNotMet             => localize('The minimum amount requirements are not met.'),
        MaximumExceeded           => localize('The amount exceeds the maximum limit.'),
        MaxPerOrderExceeded       => localize('The maximum amount exceeds the maximum amount per order ([_1] [_2]). Please adjust the value.'),
        AlreadyInProgress         => localize('This cannot be cancelled since the order is already in progress.'),
        InvalidNumericValue       => localize('Numeric value should be greater than 0.'),
        InvalidMinMaxAmount       => localize('The minimum amount should be less than or equal to maximum amount.'),
        InvalidMaxAmount          => localize('The maximum amount should be less than or equal to the advert amount.'),
        InvalidListLimit          => localize("Invalid value for list limit"),
        InvalidListOffset         => localize("Invalid value for list offset"),
        RateTooSmall              => localize('Advert rate should not be less than [_1]. Please adjust the value.'),
        RateTooBig                => localize('Advert rate should not be more than [_1]. Please adjust the value.'),
        MinPriceTooSmall          => localize('Advert minimum price is zero, Please adjust minimum amount or rate.'),
        AdvertPaymentInfoRequired => localize('Please include your payment information.'),
        AdvertContactInfoRequired => localize('Please include your contact information.'),
        OrderPaymentInfoRequired  => localize('Please include your payment information.'),
        OrderContactInfoRequired  => localize('Please include your contact information.'),
        AdvertPaymentContactInfoNotAllowed => localize('Contact and payment information are not applicable for this ad.'),
        OrderPaymentContactInfoNotAllowed  => localize('Contact and payment information are not applicable for this order.'),

        # bom-user errors
        AlreadyRegistered             => localize('This account has already been registered as a P2P advertiser.'),
        AdvertiserNotFound            => localize('P2P advertiser not found.'),
        AdvertiserNotRegistered       => localize('This account is not registered as a P2P advertiser.'),
        AdvertiserNotListed           => localize('The provided advertiser ID does not belong to an active advertiser.'),
        AdvertiserNotApproved         => localize('The advertiser is not approved.'),
        AdvertiserNameRequired        => localize('The advertiser name cannot be blank.'),
        OrderAlreadyConfirmed         => localize('The order is already confirmed by you.'),
        OrderAlreadyCancelled         => localize('The order is already cancelled.'),
        AdvertNoEditInactive          => localize('The advert is inactive and cannot be changed.'),
        AdvertNotFound                => localize('Advert not found.'),
        AdvertIsDisabled              => localize('Advert is inactive.'),
        AdvertInsufficientAmount      => localize('The new amount cannot be less than the value of current orders against this advert.'),
        AdvertMaxExceeded             => localize('The maximum limit of active adverts reached.'),
        ClientDailyOrderLimitExceeded => localize('You may only place [_1] orders every 24 hours. Please try again later.'),
        InvalidOrderCurrency          => localize('You cannot create an order with a different currency than your account.'),
        OrderNotFound                 => localize('Order not found.'),
        OrderAlreadyExists            => localize('Too many orders. Please complete your pending orders.'),
        InvalidAdvertOwn              => localize('You cannot create an order for your own advert.'),
        OrderNoEditExpired            => localize('The order has expired and cannot be changed.'),
        InvalidStateForConfirmation   => localize('The order cannot be confirmed in its current state.'),
        EscrowNotFound                => localize('Advertising for the currency is not available at the moment.'),
        OrderMinimumNotMet => localize('The minimum amount for this advert is [_1] [_2].'),    # minimum won't change during advert lifetime
        OrderMaximumExceeded   => localize('The maximum available amount for this advert is [_1] [_2] at the moment.'),
        InsufficientBalance    => localize('Your account balance is insufficient to create an order with this amount.'),
        OpenOrdersDeleteAdvert => localize(
            "This advert cannot be deleted because there are open orders. Please wait until the orders are closed and try again. If you'd like to stop accepting new orders, you may disable your advert."
        ),
        AdvertiserNameTaken => localize('The advertiser name is already taken. Please choose another.'),
    );
};

# To prevent duplicated messages, we only keep them in `%ERROR_MAP`
# so for each DB error here, there should be a corresponding error code there
our %DB_ERRORS = (
    BI225 => 'AdvertNotFound',
    BI226 => 'InvalidAdvertOwn',
    BI227 => 'AdvertInsufficientAmount',
    BI228 => 'OrderNotFound',
    BI229 => 'InvalidStateForConfirmation',
    BI230 => 'InvalidStateForConfirmation',
    BI231 => 'OrderNotFound',
    BI232 => 'AlreadyInProgress',
    BI233 => 'OrderNotFound',
    BI234 => 'InvalidStateForConfirmation',
    BI235 => 'OrderNotFound',
    BI236 => 'InvalidStateForConfirmation',
    BI237 => 'InvalidOrderCurrency',
    BI238 => 'ClientDailyOrderLimitExceeded',
    BI239 => 'OpenOrdersDeleteAdvert',
);

sub DB_ERROR_PARAMS {
    return {'ClientDailyOrderLimitExceeded' => [BOM::Config::Runtime->instance->app_config->payments->p2p->limits->count_per_day_per_client]};
}

=head2 p2p_rpc

Helper function for wrapping error handling around our P2P-related RPC calls.

Takes the following parameters:

=over 4

=item * C<$method> - which method to expose, e.g. C<p2p_order_create>

=item * C<$code> - the coderef to call

=back

C<$code> will be called with the following named parameters:

=over 4

=item * C<client> - the L<BOM::User::Client> instance

=item * C<account> - the L<BOM::User::Client::Account> instance

=item * C<app_config> - current app config as provided by L<BOM::Config::Runtime/app_config>

=item * C<params> - whatever parameters were passed through the RPC call

=back

Example usage:

 p2p_rpc p2p_order_create => sub { create_order($client, $params->{amount}) };

=cut

sub p2p_rpc {
    my ($method, $code) = @_;
    return rpc $method => category => 'p2p',
        sub {
        my $params = shift;
        try {
            my $app_config = BOM::Config::Runtime->instance->app_config;
            my $client     = $params->{client};

            _check_client_access($client, $app_config);

            my $acc = $client->default_account;

            return $code->(
                client     => $client,
                account    => $acc,
                app_config => $app_config,
                params     => $params
            );
        }
        catch {
            my $exception = $@;
            my ($err_code, $err_code_db, $err_params, $err_details);

            # db errors come as [ BIxxx, message ]
            # bom-user and bom-rpc errors come as a hashref:
            #   {error_code => 'ErrorCode', message_params => ['values for message placeholders'], details => {}}
            SWITCH: for (ref $exception) {
                if (/ARRAY/) {
                    $err_code_db = $exception->[0];
                    $err_code    = $DB_ERRORS{$err_code_db};
                    $err_params  = DB_ERROR_PARAMS->{$err_code};
                    last SWITCH;
                }

                if (/HASH/) {
                    $err_code    = $exception->{error_code};
                    $err_params  = $exception->{message_params};
                    $err_details = $exception->{details};
                    last SWITCH;
                }

                chomp($err_code = $exception);
            }

            my $p2p_prefix = $method =~ tr/_/./;

            if (my $message = $ERROR_MAP{$err_code}) {
                stats_inc($p2p_prefix . '.error', {tags => ['error_code:' . $err_code]});

                $log->debugf("P2P %s raised a DB exception, exception code is %s, original: %s", $method, $err_code_db, $message)
                    if $err_code_db;    # original DB error may have useful details

                return BOM::RPC::v3::Utility::create_error({
                    code              => $err_code,
                    message_to_client => localize($message, (ref($err_params) eq 'ARRAY' ? $err_params : [])->@*),
                    (ref($err_details) eq 'HASH' ? (details => $err_details) : ()),
                });
            } else {
                # This indicates a bug in the code.
                stats_inc($p2p_prefix . '.error', {tags => ['error_code:unknown']});

                my $db_error = $err_code_db ? " (DB error: $err_code_db)" : '';
                $log->warnf("Unexpected error in P2P %s: %s%s, please report as a bug to backend", $method, $err_code, $db_error);

                return BOM::RPC::v3::Utility::create_error({
                    code              => 'P2PError',
                    message_to_client => localize('Sorry, an error occurred.'),
                });
            }
        }
        };
}

=head2 p2p_advertiser_create

Requests registration for an advertiser account.

Each client is able to have at most one advertiser account.

Takes the following named parameters:

=over 4

=item * C<name> - the display name to be shown for this advertiser

=back

Returns a hashref with the following keys:

=over 4

=item * C<status> - usually C<pending>, unless this client is from a landing company
that does not allow P2P advertiser yet, or they already have an advertiser account.

=back

=cut

p2p_rpc p2p_advertiser_create => sub {
    my (%args) = @_;

    my $client     = $args{client};
    my $advertiser = $client->p2p_advertiser_create($args{params}{args}->%*);

    BOM::Platform::Event::Emitter::emit(
        p2p_advertiser_created => {
            client_loginid => $client->loginid,
            $advertiser->%*
        });

    return $advertiser;
};

=head2 p2p_advertiser_update

Update advertiser details.

Takes the following named parameters:

=over 4

=item * C<name> - The advertiser's display name

=item * C<is_listed> - If the advertiser's adverts are listed

=back

Returns a hashref containing the current advertiser details.

=cut

p2p_rpc p2p_advertiser_update => sub {
    my (%args) = @_;

    my $client     = $args{client};
    my $advertiser = $client->p2p_advertiser_update($args{params}{args}->%*);

    BOM::Platform::Event::Emitter::emit(
        p2p_advertiser_updated => {
            client_loginid => $client->loginid,
            advertiser_id  => $advertiser->{id},
        },
    );

    return $advertiser;
};

=head2 p2p_advertiser_info

Returns information about the given advertiser (by ID).

Takes the following named parameters:

=over 4

=item * C<id> - The internal ID of the advertiser

=back

Returns a hashref containing the following information:

=over 4

=item * C<id> - The advertiser's identification number

=item * C<name> - The advertiser's displayed name

=item * C<client_loginid> - The loginid of the advertiser

=item * C<created_time> - The epoch time that the client became an advertiser

=item * C<is_active> - The activation status of the advertiser

=item * C<is_authenticated> - The authentication status of the advertiser

=back

=cut

p2p_rpc p2p_advertiser_info => sub {
    my (%args) = @_;

    my $client = $args{client};
    return $client->p2p_advertiser_info($args{params}{args}->%*) // die +{error_code => 'AdvertiserNotFound'};
};

p2p_rpc p2p_advertiser_adverts => sub {
    my (%args) = @_;

    my $client = $args{client};
    return {list => $client->p2p_advertiser_adverts($args{params}{args}->%*)};
};

=head2 p2p_method_list

Returns a list of all available payment methods.

=cut

p2p_rpc p2p_method_list => sub {
    return [{
            method       => 'bank',
            name         => 'hsbc',
            display_name => 'HSBC'
        },
        {
            method => 'bank',
            name   => 'maybank',
            name   => 'Maybank'
        },
        {
            method => 'bank',
            name   => 'cimb',
            name   => 'CIMB'
        },
        {
            method => 'online',
            name   => 'alipay',
            name   => 'AliPay'
        },
        {
            method    => 'online',
            name      => 'fps',
            full_name => 'FPS'
        },
        {
            method    => 'mobile',
            name      => 'grabpay',
            full_name => 'GrabPay'
        },
        {
            method    => 'mobile',
            name      => 'jompay',
            full_name => 'JOMPay'
        },
        {
            method => 'other',
            name   => 'other',
            name   => 'Other'
        },
    ];
};

=head2 p2p_advert_create

Attempts to create a new advert.

Takes the following named parameters:

=over 4

=item * C<advertiser_id> - the internal ID of the advertiser (if the client only has one ID, will use that one)

=item * C<min_order_amount> - minimum amount per order (in C<account_currency>)

=item * C<max_order_amount> - maximum amount per order (in C<account_currency>)

=item * C<amount> - total amount for all orders on this advert (in C<account_currency>)

=item * C<local_currency> - currency the advertiser/client transaction will be conducted in (outside our system)

=item * C<rate> - the price (in C<local_currency>)

=item * C<type> - either C<buy> or C<sell>

=back

Returns a hashref which contains the advert ID and the details of the advert (mostly just a repeat of the
above information).

=cut

p2p_rpc p2p_advert_create => sub {
    my (%args) = @_;

    my $client = $args{client};
    return $client->p2p_advert_create($args{params}{args}->%*);
};

=head2 p2p_advert_info

Returns information about an advert.

Returns a hashref containing the following keys:

=over 4

=item * C<advertiser_id> - the internal ID of the advertiser (if the client only has one ID, will use that one)

=item * C<id> - the internal ID of this advert

=item * C<min_order_amount> - minimum amount per order (in C<account_currency>)

=item * C<max_order_amount> - maximum amount per order (in C<account_currency>)

=item * C<amount> - total amount for all orders on this advert (in C<account_currency>)

=item * C<account_currency> - currency to be credited/debited from the Binary accounts

=item * C<local_currency> - currency the advertiser/client transaction will be conducted in (outside our system)

=item * C<price> - the price (in C<local_currency>)

=item * C<is_active> - true if orders can be created against this advert

=item * C<type> - either C<buy> or C<sell>

=back

=cut

p2p_rpc p2p_advert_info => sub {
    my (%args) = @_;

    my $client = $args{client};
    return $client->p2p_advert_info($args{params}{args}->%*) // die +{error_code => 'AdvertNotFound'};
};

=head2 p2p_advert_list

Takes the following named parameters:

=over 4

=item * C<advertiser_id> - the internal ID of the advertiser

=item * C<type> - either C<buy> or C<sell>

=back

Returns available adverts as an arrayref containing hashrefs with the following keys:

=over 4

=item * C<advertiser_id> - the internal ID of the advertiser (if the client only has one ID, will use that one)

=item * C<id> - the internal ID of this advert

=item * C<min_order_amount> - minimum amount per order (in C<account_currency>)

=item * C<max_order_amount> - maximum amount per order (in C<account_currency>)

=item * C<amount> - total amount for all orders on this advert (in C<account_currency>)

=item * C<account_currency> - currency to be credited/debited from the Binary accounts

=item * C<local_currency> - currency the advertiser/client transaction will be conducted in (outside our system)

=item * C<price> - the price (in C<local_currency>)

=item * C<is_active> - true if orders can be created against this advert

=item * C<type> - either C<buy> or C<sell>

=back

=cut

p2p_rpc p2p_advert_list => sub {
    my %args = @_;

    my $client = $args{client};
    return {list => $client->p2p_advert_list($args{params}{args}->%*)};
};

=head2 p2p_advert_update

Modifies details on an advert.

=cut

p2p_rpc p2p_advert_update => sub {
    my %args = @_;

    my $client = $args{client};
    return $client->p2p_advert_update($args{params}{args}->%*) // die +{error_code => 'AdvertNotFound'};
};

=head2 p2p_order_create

Creates a new order for an advert.

=cut

p2p_rpc p2p_order_create => sub {
    my %args = @_;

    my $client = $args{client};

    my $order = $client->p2p_order_create($args{params}{args}->%*, source => $args{params}{source});

    BOM::Platform::Event::Emitter::emit(
        p2p_order_created => {
            client_loginid => $client->loginid,
            order_id       => $order->{id},
        });

    return $order;
};

=head2 p2p_order_list

Lists orders.

Takes the following named parameters:

=over 4

=item * C<status> - return only records matching the given status

=item * C<advertiser_id> - lists only for this advertiser (if not provided, lists orders owned
by the current client)

=item * C<advert_id> - lists only the orders for the given advert (this is only available
if the current client owns that advert)

=item * C<limit> - limit number of items returned in list

=item * C<offset> - set offset for list

=back

=cut

p2p_rpc p2p_order_list => sub {
    my %args = @_;

    my $client = $args{client};
    return {list => $client->p2p_order_list($args{params}{args}->%*)};
};

=head2 p2p_order_info

Returns information about a specific order.

Takes the following named parameters:

=over 4

=item * C<id> - the P2P order ID to look up

=back

=cut

p2p_rpc p2p_order_info => sub {
    my %args = @_;

    my ($client, $params) = @args{qw/client params/};
    return $client->p2p_order_info($args{params}{args}->%*) // die +{error_code => 'OrderNotFound'};
};

=head2 p2p_order_confirm

Shortcut for updating order status to C<confirmed>.

Takes the following named parameters:

=over 4

=item * C<id> - p2p order ID

=back

=cut

p2p_rpc p2p_order_confirm => sub {
    my %args = @_;

    my ($client, $params) = @args{qw/client params/};

    my $order_id = $params->{args}{id};

    my $order = $client->p2p_order_confirm(
        id     => $order_id,
        source => $params->{source});

    BOM::Platform::Event::Emitter::emit(
        p2p_order_updated => {
            client_loginid => $client->loginid,
            order_id       => $order_id,
        });

    return {
        id     => $order->{id},
        status => $order->{status},
    };
};

=head2 p2p_order_cancel

Shortcut for updating order status to C<cancelled>.

Takes the following named parameters:

=over 4

=item * C<id> - p2p order id

=back

=cut

p2p_rpc p2p_order_cancel => sub {
    my %args = @_;

    my ($client, $params) = @args{qw/client params/};

    my $order_id = $params->{args}{id};

    my $order = $client->p2p_order_cancel(
        id     => $order_id,
        source => $params->{source});

    BOM::Platform::Event::Emitter::emit(
        p2p_order_updated => {
            client_loginid => $client->loginid,
            order_id       => $order_id,
        });

    return {
        id     => $order_id,
        status => $order->{status},
    };
};

=head2 p2p_order_chat

Exchange chat messages.

=cut

p2p_rpc p2p_order_chat => sub {
    die +{error_code => 'PermissionDenied'};
};

# Check to see if the client can has access to p2p API calls or not?
# Does nothing if client has access or die
sub _check_client_access {
    my ($client, $app_config) = @_;

    # Yes, we have two ways to disable - devops can shut it down if there
    # are problems, and payments/ops/QA can choose whether or not the
    # functionality should be exposed in the first place. The ->p2p->enabled
    # check may be dropped in future once this is stable.
    die +{error_code => 'P2PDisabled'} if $app_config->system->suspend->p2p;
    die +{error_code => 'P2PDisabled'} unless $app_config->payments->p2p->enabled;

    # All operations require a valid client with active account
    $client // die +{error_code => 'NotLoggedIn'};

    die +{error_code => 'UnavailableOnVirtual'} if $client->is_virtual;

    die +{error_code => 'PermissionDenied'} if $client->status->has_any(@{RESTRICTED_CLIENT_STATUSES()});

    # Allow user to pass if payments.p2p.available is checked or client login id is in payments.p2p.clients
    die +{error_code => 'PermissionDenied'}
        unless $app_config->payments->p2p->available || any { $_ eq $client->loginid } $app_config->payments->p2p->clients->@*;

    die +{error_code => 'RestrictedCountry'}
        unless any { $_ eq lc($client->residence // '') } $app_config->payments->p2p->available_for_countries->@*;

    die +{error_code => 'NoCurrency'} unless $client->default_account;

    die "RestrictedCurrency\n" unless any { $_ eq lc($client->currency) } $app_config->payments->p2p->available_for_currencies->@*;

    die "NoCountry\n" unless $client->residence;

}

1;
