package BOM::RPC::v3::P2P;

=head1 NAME

BOM::RPC::v3::P2P - peer-to-peer "over-the-counter" payment support

=head1 DESCRIPTION

The P2P cashier is a system which allows buyers and sellers to handle the details
of payments outside our system. It acts as a marketplace for offers and orders.

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
# of orders or offers, but also no value to us in doing so.
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
        NotRegistered    => localize('You are not yet registered as an P2P agent.'),

        # Invalid data
        InvalidPaymentMethod => localize('This payment method is invalid.'),
        NotFound             => localize('Not found.'),
        MinimumNotMet        => localize('The minimum amount requirements are not met.'),
        MaximumExceeded      => localize('The amount exceeds the maximum limit.'),
        MaxPerOrderExceeded  => localize('The maximum amount exceeds the maximum amount per order ([_1] [_2]). Please adjust the value.'),
        AlreadyInProgress    => localize('This cannot be cancelled since the order is already in progress.'),
        InvalidNumericValue  => localize('Numeric value should be greater than 0.'),
        InvalidMinMaxAmount  => localize('The minimum amount should be less than or equal to maximum amount.'),
        InvalidMaxAmount     => localize('The maximum amount should be less than or equal to the offer amount.'),
        InvalidListLimit     => localize("Invalid value for list limit"),
        InvalidListOffset    => localize("Invalid value for list offset"),
        RateTooSmall         => localize('Ad rate should not be less than [_1]. Please adjust the value.'),
        RateTooBig           => localize('Ad rate should not be more than [_1]. Please adjust the value.'),
        MinPriceTooSmall     => localize('Ad minimum price is zero, Please adjust minimum amount or rate.'),

        # bom-user errors
        AgentNotFound               => localize('P2P Agent not found.'),
        AgentNotRegistered          => localize('This account is not registered as an P2P agent.'),
        AgentNotActive              => localize('The provided agent ID does not belong to an active agent.'),
        AgentNotApproved            => localize('The agent is not approved.'),
        AgentNameRequired           => localize('The agent name cannot be blank.'),
        OrderAlreadyConfirmed       => localize('The order is already confirmed by you.'),
        OrderAlreadyCancelled       => localize('The order is already cancelled.'),
        OfferNoEditInactive         => localize('The offer is inactive and cannot be changed.'),
        OfferNotFound               => localize('Offer not found.'),
        OfferIsDisabled             => localize('Offer is inactive.'),
        OfferInsufficientAmount     => localize('The new amount cannot be less than the value of current orders against this offer.'),
        OfferMaxExceeded            => localize('The maximum limit of active offers reached.'),
        InvalidOrderCurrency        => localize('You cannot create an order with a different currency than your account.'),
        OrderNotFound               => localize('Order not found.'),
        OrderAlreadyExists          => localize('Too many orders. Please complete your pending orders.'),
        InvalidOfferOwn             => localize('You cannot create an order for your own offer.'),
        OrderNoEditExpired          => localize('The order has expired and cannot be changed.'),
        InvalidStateForConfirmation => localize('The order cannot be confirmed in its current state.'),
        EscrowNotFound              => localize('Offering for the currency is not available at the moment.'),
        OrderMinimumNotMet => localize('The minimum amount for this offer is [_1] [_2].'),    # minimum won't change during offer lifetime
        OrderMaximumExceeded => localize('The maximum available amount for this offer is [_1] [_2] at the moment.'),

        InsufficientBalance => localize('Your account balance is insufficient to create an order with this amount.'),
    );
};

# To prevent duplicated messages, we only keep them in `%ERROR_MAP`
# so for each DB error here, there should be a corresponding error code there
our %DB_ERRORS = (
    BI225 => 'OfferNotFound',
    BI226 => 'InvalidOfferOwn',
    BI227 => 'OfferInsufficientAmount',
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
);

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

                $log->warnf("P2P %s failed, DB failure: %s, original: %s", $method, $err_code_db, $exception->[1])
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

=head2 p2p_agent_create

Requests registration for an agent account.

Each client is able to have at most one agent account.

Takes the following named parameters:

=over 4

=item * C<name> - the display name to be shown for this agent

=back

Returns a hashref with the following keys:

=over 4

=item * C<status> - usually C<pending>, unless this client is from a landing company
that does not allow P2P agents yet, or they already have an agent account.

=back

=cut

p2p_rpc p2p_agent_create => sub {
    my (%args) = @_;
    my $client = $args{client};
    my $name   = $args{params}{args}{agent_name};
    my $agent  = $client->p2p_agent_create($name);
    BOM::Platform::Event::Emitter::emit(p2p_agent_created => $agent);
    return {status => 'pending'};
};

=head2 p2p_agent_update

Update agent details.

Takes the following named parameters:

=over 4

=item * C<agent_name> - The agent's display name

=item * C<is_active> - The activation status of the agent

=back

Returns a hashref containing the current agent details.

=cut

p2p_rpc p2p_agent_update => sub {
    my (%args) = @_;

    my $client = $args{client};
    return $client->p2p_agent_update($args{params}{args}->%*);
};

=head2 p2p_agent_info

Returns information about the given agent (by ID).

Takes the following named parameters:

=over 4

=item * C<agent_id> - The internal ID of the agent

=back

Returns a hashref containing the following information:

=over 4

=item * C<agent_id> - The agent's identification number

=item * C<agent_name> - The agent's displayed name

=item * C<client_loginid> - The loginid of the agent

=item * C<created_time> - The epoch time that the client became an agent

=item * C<is_active> - The activation status of the agent

=item * C<is_authenticated> - The authentication status of the agent

=back

=cut

p2p_rpc p2p_agent_info => sub {
    my (%args) = @_;

    my $client = $args{client};
    return $client->p2p_agent_info($args{params}{args}->%*) // die +{error_code => 'AgentNotFound'};
};

p2p_rpc p2p_agent_offers => sub {
    my (%args) = @_;
    my $client = $args{client};
    return {list => $client->p2p_agent_offers($args{params}{args}->%*)};
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

=head2 p2p_offer_create

Attempts to create a new offer.

Takes the following named parameters:

=over 4

=item * C<agent_id> - the internal ID of the agent (if the client only has one ID, will use that one)

=item * C<min> - minimum amount per order (in C<local_currency>)

=item * C<max> - maximum amount per order (in C<local_currency>)

=item * C<total> - total amount for all orders on this offer (in C<local_currency>)

=item * C<currency> - currency to be credited/debited from the Binary accounts

=item * C<local_currency> - currency the agent/client transaction will be conducted in (outside our system)

=item * C<price> - the price (in C<local_currency>)

=item * C<active> - whether to create it as active or disabled

=item * C<type> - either C<buy> or C<sell>

=back

Returns a hashref which contains the offer ID and the details of the offer (mostly just a repeat of the
above information).

=cut

p2p_rpc p2p_offer_create => sub {
    my (%args) = @_;

    my $client = $args{client};
    return $client->p2p_offer_create($args{params}{args}->%*);
};

=head2 p2p_offer_info

Returns information about an offer.

Returns a hashref containing the following keys:

=over 4

=item * C<agent_id> - the internal ID of the agent (if the client only has one ID, will use that one)

=item * C<id> - the internal ID of this offer

=item * C<min> - minimum amount per order (in C<local_currency>)

=item * C<max> - maximum amount per order (in C<local_currency>)

=item * C<total> - total amount for all orders on this offer (in C<local_currency>)

=item * C<currency> - currency to be credited/debited from the Binary accounts

=item * C<local_currency> - currency the agent/client transaction will be conducted in (outside our system)

=item * C<price> - the price (in C<local_currency>)

=item * C<active> - true if orders can be created against this offer

=item * C<type> - either C<buy> or C<sell>

=back

=cut

p2p_rpc p2p_offer_info => sub {
    my (%args) = @_;

    my $client = $args{client};
    return $client->p2p_offer_info($args{params}{args}->%*) // die +{error_code => 'OfferNotFound'};
};

=head2 p2p_offer_list

Takes the following named parameters:

=over 4

=item * C<agent_id> - the internal ID of the agent

=item * C<type> - either C<buy> or C<sell>

=back

Returns available offers as an arrayref containing hashrefs with the following keys:

=over 4

=item * C<agent_id> - the internal ID of the agent (if the client only has one ID, will use that one)

=item * C<id> - the internal ID of this offer

=item * C<min> - minimum amount per order (in C<local_currency>)

=item * C<max> - maximum amount per order (in C<local_currency>)

=item * C<total> - total amount for all orders on this offer (in C<local_currency>)

=item * C<currency> - currency to be credited/debited from the Binary accounts

=item * C<local_currency> - currency the agent/client transaction will be conducted in (outside our system)

=item * C<price> - the price (in C<local_currency>)

=item * C<active> - true if orders can be created against this offer

=item * C<type> - either C<buy> or C<sell>

=back

=cut

p2p_rpc p2p_offer_list => sub {
    my %args = @_;

    my $client = $args{client};
    return {list => $client->p2p_offer_list($args{params}{args}->%*)};
};

=head2 p2p_offer_update

Modifies details on an offer.

=cut

p2p_rpc p2p_offer_update => sub {
    my %args = @_;

    my $client = $args{client};
    return $client->p2p_offer_update($args{params}{args}->%*) // die +{error_code => 'OfferNotFound'};
};

=head2 p2p_order_create

Creates a new order for an offer.

=cut

p2p_rpc p2p_order_create => sub {
    my %args = @_;

    my $client = $args{client};

    my $offer_id = $args{params}{args}{offer_id};
    my $order = $client->p2p_order_create($args{params}{args}->%*, source => $args{params}{source});

    BOM::Platform::Event::Emitter::emit(
        p2p_order_created => {
            client_loginid => $client->loginid,
            order_id       => $order->{order_id},
        });

    return $order;
};

=head2 p2p_order_list

Lists orders.

Takes the following named parameters:

=over 4

=item * C<status> - return only records matching the given status

=item * C<agent_id> - lists only for this agent (if not provided, lists orders owned
by the current client)

=item * C<offer_id> - lists only the orders for the given offer (this is only available
if the current client owns that offer)

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

=item * C<order_id> - the P2P order ID to look up

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

=item * C<order_id> - p2p order ID

=back

=cut

p2p_rpc p2p_order_confirm => sub {
    my %args = @_;

    my ($client, $params) = @args{qw/client params/};

    my $order_id = $params->{args}{order_id};

    my $order = $client->p2p_order_confirm(
        order_id => $order_id,
        source   => $params->{source});

    BOM::Platform::Event::Emitter::emit(
        p2p_order_updated => {
            client_loginid => $client->loginid,
            order_id       => $order_id,
        });

    return {
        order_id => $order->{order_id},
        status   => $order->{status},
    };
};

=head2 p2p_order_cancel

Shortcut for updating order status to C<cancelled>.

Takes the following named parameters:

=over 4

=item * C<order_id> - p2p order id

=back

=cut

p2p_rpc p2p_order_cancel => sub {
    my %args = @_;

    my ($client, $params) = @args{qw/client params/};

    my $order_id = $params->{args}{order_id};

    my $order = $client->p2p_order_cancel(
        order_id => $order_id,
        source   => $params->{source});

    BOM::Platform::Event::Emitter::emit(
        p2p_order_updated => {
            client_loginid => $client->loginid,
            order_id       => $order_id,
        });

    return {
        order_id => $order_id,
        status   => $order->{status},
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

    die +{error_code => 'NoCurrency'} unless $client->default_account;
}

1;
