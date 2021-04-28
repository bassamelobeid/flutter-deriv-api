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
use List::Util qw (any none);

use BOM::User::Client;
use BOM::Platform::Context qw (localize request);
use BOM::Config;
use BOM::Config::Runtime;
use BOM::User;
use BOM::RPC::v3::Utility qw(log_exception);
use ExchangeRates::CurrencyConverter qw(convert_currency);
use Format::Util::Numbers qw/financialrounding formatnumber/;

use BOM::RPC::Registry '-dsl';

use Log::Any qw($log);

# Currently all functionality is restricted to users with
# valid accounts. There's little harm in allowing a list
# of orders or adverts, but also no value to us in doing so.
requires_auth('wallet');

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
        NoCountry            => localize("Please set your country of residence."),
        NoCurrency           => localize("Please set your account currency."),
        P2PDisabled          => localize("P2P cashier is currently unavailable. Please check back later."),
        RestrictedCountry    => localize("P2P cashier is unavailable in your country."),
        RestrictedCurrency   => localize("[_1] is not supported at the moment."),
        UnavailableOnVirtual => localize("P2P cashier is unavailable on demo accounts. Please switch to your real account."),

        # Client status
        NoLocalCurrency  => localize("We cannot recognise your local currency. Please contact our Customer Support team."),    # TODO maybe this?
        NotLoggedIn      => localize("Please log in to continue."),
        PermissionDenied => localize("You cannot perform this action because of your account status. Please contact our Customer Support team."),

        # Invalid data
        AdvertContactInfoRequired          => localize("Please provide your contact details."),
        AdvertPaymentContactInfoNotAllowed => localize("Payment and contact information are not needed for buy ads."),
        AdvertPaymentInfoRequired          => localize("Please provide your payment details."),
        AlreadyInProgress                  => localize("Order is in progress. Changes are no longer allowed."),
        InvalidListLimit                   => localize("Please enter a limit value that's greater than 0."),
        InvalidListOffset                  => localize("The offset value cannot be negative. Please enter 0 or higher."),
        InvalidMaxAmount                   => localize("This value should be less than or equal to the ad amount."),
        InvalidMinMaxAmount => localize("The minimum order amount should be less than or equal to the maximum ad amount. Please adjust the value."),
        InvalidNumericValue => localize("Please enter a value that's greater than 0."),
        MaximumExceeded     => localize("Maximum ad limit is [_1] [_2]. Please adjust the value."),
        MaxPerOrderExceeded => localize("Maximum ad order amount is [_1] [_2]. Please adjust the value."),
        MinPriceTooSmall    => localize("Minimum order amount is [_1]. Please adjust the value."),
        OrderContactInfoRequired          => localize("Please provide your contact details."),
        OrderPaymentContactInfoNotAllowed => localize("Buy orders do not require payment and contact information."),
        OrderPaymentInfoRequired          => localize("Please provide your payment details."),
        RateTooBig                        => localize("Ad rate should not be more than [_1]. Please adjust the value."),
        RateTooSmall                      => localize("Ad rate should not be less than [_1]. Please adjust the value."),

        # bom-user errors
        AdvertIsDisabled             => localize("This ad is currently unavailable. Please choose another ad or check back later."),
        OrderCreateFailAdvertiser    => localize("This ad is currently unavailable. Please choose another ad or check back later."),
        OrderCreateFailClient        => localize("There was a problem in placing this order. [_1]"),
        OrderCreateFailClientBalance => localize('The amount of the order exceeds your funds available in DP2P.'),
        OrderCreateFailBalance       => localize("An order cannot be created for this amount at this time. Please try adjusting the amount."),
        AdvertiserNameRequired       => localize("Please provide your name."),
        AdvertiserNameTaken          => localize("This name is already in use. Please provide a different name."),
        AdvertiserNotApproved        =>
            localize("Before you can post an ad, we need to verify your identity. Please complete your identity verification at Deriv.com."),
        AdvertiserNotFound      => localize("We can't find the advertiser. Please review the details and try again."),
        AdvertiserNotListed     => localize("This advertiser is currently inactive. Please check again later or choose another advertiser."),
        AdvertiserNotRegistered => localize("Please apply to be an advertiser. If you've already applied, please contact our Customer Support team."),
        AdvertMaxExceeded       => localize("You've reached the maximum ad limit. Please deactivate some ads."),
        AdvertMaxExceededSameType =>
            localize("You've reached the maximum of [_1] active ads for this currency pair and order type. Please delete an ad to place a new one."),
        DuplicateAdvert =>
            localize("You have another active ad with the same rate for this currency pair and order type. Please set a different rate."),
        AdvertSameLimits => localize(
            "Please change the minimum and/or maximum order limit for this ad. The range between these limits must not overlap with another active ad you created for this currency pair and order type."
        ),
        AdvertNotFound                => localize("We can't find the ad. Please review the details or try another ad."),
        AdvertOwnerNotApproved        => localize("This advertiser has not been approved yet. Please choose another advertiser."),
        AlreadyRegistered             => localize("You are already an advertiser."),
        ClientDailyOrderLimitExceeded => localize("You may only place [_1] orders every 24 hours. Please try again later."),
        EscrowNotFound                =>
            localize("Advertising for this currency is currently unavailable. Please contact our Customer Support team or try again later."),
        InvalidAdvertOwn              => localize("You cannot place an order for your own ad."),
        InvalidOrderCurrency          => localize("Please select an ad that matches your currency."),
        OpenOrdersDeleteAdvert        => localize("You have open orders for this ad. Please wait until all orders are closed."),
        OrderAlreadyCancelled         => localize("You've already cancelled this order."),
        OrderNotConfirmedPending      => localize("Please wait for the buyer to confirm the order."),
        OrderAlreadyConfirmedBuyer    => localize("You've already confirmed this order. Please wait for the seller to confirm."),
        OrderAlreadyConfirmedTimedout => localize(
            "You've already confirmed this order, but the seller has not. Please contact them for more information. If you need help, contact our Customer Support team."
        ),
        OrderConfirmCompleted      => localize("This order has already been completed."),
        OrderAlreadyExists         => localize("You have an active order for this ad. Please complete the order before making a new one."),
        OrderMaximumExceeded       => localize("Maximum ad amount is [_1] [_2]. Please adjust the value."),
        OrderMinimumNotMet         => localize("Minimum ad amount is [_1] [_2]. Please adjust the value."),
        OrderNoEditExpired         => localize("This order has expired and cannot be changed."),
        OrderNotFound              => localize("This order does not exist."),
        AdvertiserNotFoundForOrder => localize(
            "You are using an old version of this app, which no longer supports placing orders. Please upgrade your app to place your order.")
        ,    # Temporary error message should be removed after releasing KYC for p2p and we sure that clients updated mobile app.
        AdvertiserNotApprovedForOrder =>
            localize("Before you can place an order, we need to verify your identity. Please complete your identity verification at Deriv.com."),
        OrderMaximumTempExceeded => localize("Maximum order amount at this time is [_1] [_2]. Please adjust the value or try after 00:00 GMT."),
        OrderRefundInvalid       => localize("This order cannot be refunded or cancelled."),
        OrderCreateFailAmount    => localize("An order cannot be created for this amount at this time. Please try adjusting the amount."),

        # TODO these messages needs to be checked with copywritter team
        AdvertiserCreateChatError        => localize('An error occurred (chat user not created). Please try again later.'),
        AdvertiserNotFoundForChat        => localize('You may not chat until you have registered on the P2P system.'),
        ChatTokenError                   => localize('An error occurred when issuing a new token. Please try again later.'),
        AdvertiserNotFoundForChatToken   => localize('This account is not registered as a P2P advertiser.'),
        OrderChatAlreadyCreated          => localize('A chat for this order has already been created.'),
        CounterpartyNotAdvertiserForChat => localize('Chat is not possible because the other client is not yet registered on the P2P system.'),
        CreateChatError                  => localize('An error occurred when creating the chat. Please try again later.'),
        AdvertiserCannotListAds          => localize("You cannot list adverts because you've not been approved as an advertiser yet."),
        InvalidStateForDispute           => localize('Please wait until the order expires to raise a dispute.'),
        InvalidReasonForBuyer            => localize("This reason doesn't apply to your case. Please choose another reason."),
        InvalidReasonForSeller           => localize("This reason doesn't apply to your case. Please choose another reason."),
        OrderUnderDispute                => localize('This order is under dispute.'),
        InvalidFinalStateForDispute      => localize('This order is complete and can no longer be disputed.'),
        TemporaryBar                     =>
            localize("You've been temporarily barred from using our services due to multiple cancellation attempts. Try again after [_1]."),
        PaymentMethodNotFound     => localize('The payment method ID does not exist.'),
        InvalidPaymentMethodField => localize('[_1] is not a valid field for payment method [_2].'),
        InvalidPaymentMethod      => localize('Invalid payment method provided: [_1].'),
        MissingPaymentMethodField => localize('[_1] is a required field for payment method [_2]. Please provide a value.'),
        DuplicatePaymentMethod    => localize('You have a payment method with the same values for [_1].'),
        PaymentMethodUsedByAd     =>
            localize('This payment method is in use by the following ad(s): [_1]. Please add other payment methods to the ad, or deactivate the ad.'),
        PaymentMethodUsedByOrder    => localize('This payment method is in use by the following order(s): [_1]. Please wait until it completes.'),
        PaymentMethodInUse          => localize('This payment method is in use by multiple ads and/or orders, and cannot be deleted or deactivated.'),
        AdvertNoPaymentMethod       => localize('This advert has no payment methods. Please add at least one before activating it.'),
        InvalidPaymentMethods       => localize('Invalid payment methods provided.'),
        ActivePaymentMethodRequired => localize('At least one active payment method is required.'),
        AdvertPaymentMethodRequired => localize("Please provide a payment method."),
        PaymentMethodRemoveActiveOrders => localize('You must keep a [_1] payment method on this advert while it has active orders.'),
        PaymentMethodNotInAd            => localize('[_1] is not available as a payment method for this advert.'),
        PaymentMethodParam              => localize('payment_method field can not be updated for sell ads.'),
    );
};

# To prevent duplicated messages, we only keep them in `%ERROR_MAP`
# so for each DB error here, there should be a corresponding error code there
our %DB_ERRORS = (
    BI225 => 'AdvertNotFound',
    BI226 => 'InvalidAdvertOwn',
    BI228 => 'OrderNotFound',
    BI229 => 'OrderConfirmCompleted',
    BI230 => 'OrderNotConfirmedPending',
    BI231 => 'OrderNotFound',
    BI232 => 'AlreadyInProgress',
    BI233 => 'OrderNotFound',
    BI234 => 'OrderConfirmCompleted',
    BI235 => 'OrderNotFound',
    BI236 => 'OrderConfirmCompleted',
    BI237 => 'InvalidOrderCurrency',
    BI238 => 'ClientDailyOrderLimitExceeded',
    BI239 => 'OpenOrdersDeleteAdvert',
    BI240 => 'OrderCreateFailAmount',
    BI242 => 'OrderRefundInvalid',
    BI243 => 'OrderCreateFailBalance',
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
        } catch ($exception) {
            my ($err_code, $err_code_db, $err_params, $err_details);

            #log datadog metric
            log_exception();

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

Returns a hashref containing the created advertiser details.

=cut

p2p_rpc p2p_advertiser_create => sub {
    my (%args) = @_;

    my $client = $args{client};
    return $client->p2p_advertiser_create($args{params}{args}->%*);
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

    my $client = $args{client};
    return $client->p2p_advertiser_update($args{params}{args}->%*);
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

=head2 p2p_payment_methods

Payment Methods.

Returns available payment methods for current client's country.

=cut

p2p_rpc p2p_payment_methods => sub {
    my (%args) = @_;

    my $client = $args{client};
    return $client->p2p_payment_methods();
};

=head2 p2p_advertiser_payment_methods

Advertiser Payment Methods.

Manages advertiser payment methods:

=cut

p2p_rpc p2p_advertiser_payment_methods => sub {
    my (%args) = @_;

    my $client = $args{client};
    return $client->p2p_advertiser_payment_methods($args{params}{args}->%*);
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

    return $client->p2p_order_create($args{params}{args}->%*, source => $args{params}{source});
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

    return {
        id     => $order_id,
        status => $order->{status},
    };
};

=head2 p2p_chat_create

Creates a new chat for the specified order.

Takes the following named parameters:

=over 4

=item * C<order_id> - the P2P order ID to create the chat for

=back

Returns the information of the created chat containing:

=over 4

=item * C<channel_url> - The chat channel URL for the requested order

=item * C<order_id> - The unique identifier for the order that the chat belongs to

=back

=cut

p2p_rpc p2p_chat_create => sub {
    my %args = @_;

    my $client = $args{client};
    return $client->p2p_chat_create($args{params}{args}->%*);
};

=head2 p2p_order_dispute

Flag the order as disputed.

Takes the following named parameters:

=over 4

=item * C<id> - p2p order id

=item * C<dispute_reason> - dispute reason

=back

Returns, a C<hashref> containing the updated order data.

=cut

p2p_rpc p2p_order_dispute => sub {
    my %args = @_;

    my ($client, $params) = @args{qw/client params/};

    my $order_id       = $params->{args}{id};
    my $dispute_reason = $params->{args}{dispute_reason};

    my $order = $client->p2p_create_order_dispute(
        id             => $order_id,
        dispute_reason => $dispute_reason,
    );

    return $order;
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

    # Allow user to pass if payments.p2p.available is checked or client login id is in payments.p2p.clients
    die +{error_code => 'P2PDisabled'}
        unless $app_config->payments->p2p->available || any { $_ eq $client->loginid } $app_config->payments->p2p->clients->@*;

    my @available_countries = $app_config->payments->p2p->available_for_countries->@*;
    die +{error_code => 'RestrictedCountry'} if @available_countries and none { $_ eq lc($client->residence // '') } @available_countries;

    my @restricted_countries = $app_config->payments->p2p->restricted_countries->@*;
    die +{error_code => 'RestrictedCountry'} if any { $_ eq lc($client->residence // '') } @restricted_countries;

    die +{error_code => 'RestrictedCountry'} unless $client->landing_company->p2p_available;

    die +{error_code => 'NoCurrency'} unless $client->default_account;

    die +{
        error_code     => 'RestrictedCurrency',
        message_params => [$client->currency]}
        unless any { $_ eq lc($client->currency) } $app_config->payments->p2p->available_for_currencies->@*;

    die "NoCountry\n" unless $client->residence;

    die +{error_code => 'PermissionDenied'} if $client->status->has_any(@{RESTRICTED_CLIENT_STATUSES()});

    die +{error_code => 'PermissionDenied'} if $client->p2p_is_advertiser_blocked;
}

1;
