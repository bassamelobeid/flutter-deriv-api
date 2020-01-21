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
        AlreadyInProgress    => localize('This cannot be cancelled since the order is already in progress.'),
        InvalidNumericValue  => localize('Numeric value should be greater than 0.'),
        InvalidMinMaxAmount  => localize('The minimum amount should be less than or equal to maximum amount.'),
        InvalidMaxAmount     => localize('The maximum amount should be less than or equal to the offer amount.'),
        InvalidListLimit     => localize("Invalid value for list limit"),
        InvalidListOffset    => localize("Invalid value for list offset"),

        # bom-user errors
        AgentNotFound               => localize('P2P Agent not found.'),
        AgentNotRegistered          => localize('This account is not registered as an P2P agent.'),
        AgentNotActive              => localize('The provided agent ID does not belong to an active agent.'),
        AgentNotAuthenticated       => localize('The agent is not authenticated.'),
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

        # DB errors
        BI225 => localize('Offer not found.'),
        BI226 => localize('Cannot create order for your own offer.'),
        BI227 => localize('Insufficient funds in account'),
        BI228 => localize('Order not found.'),
        BI229 => localize('Order cannot be completed in its current state.'),
        BI230 => localize('Order has not been confirmed by agent.'),
        BI231 => localize('Order not found.'),
        BI232 => localize('Order cannot be cancelled in its current state.'),
        BI233 => localize('Order not found.'),
        BI234 => localize('Order cannot be agent confirmed in its current state.'),
        BI235 => localize('Order not found.'),
        BI236 => localize('Order cannot be client confirmed in its current state.'),
        BI237 => localize('Order currency is different from account currency.'),
    );
};

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

            # Yes, we have two ways to disable - devops can shut it down if there
            # are problems, and payments/ops/QA can choose whether or not the
            # functionality should be exposed in the first place. The ->p2p->enabled
            # check may be dropped in future once this is stable.
            die "P2PDisabled\n" if $app_config->system->suspend->p2p;
            die "P2PDisabled\n" unless $app_config->payments->p2p->enabled;

            # All operations require a valid client with active account
            my $client = $params->{client}
                or die "NotLoggedIn\n";

            die "UnavailableOnVirtual\n" if $client->is_virtual;

            die "PermissionDenied\n" if $client->status->has_any(@{RESTRICTED_CLIENT_STATUSES()});

            my $acc = $client->default_account
                or die "NoCurrency\n";

            return $code->(
                client     => $client,
                account    => $acc,
                app_config => $app_config,
                params     => $params
            );
        }
        catch {
            my $exception = $@;
            my ($err, $err_params, $err_details);
            # db errors come as [ BIxxx, message ]
            # bom-user errors come as a string "ErrorCode\n"
            #   or a HASH: {error_code => 'ErrorCode', message_params => ['values for message placeholders']}
            SWITCH: for (ref $exception) {
                if (/ARRAY/) { $err = $exception->[0]; last SWITCH; }
                if (/HASH/) {
                    $err         = $exception->{error_code};
                    $err_params  = $exception->{message_params};
                    $err_details = $exception->{details};
                    last SWITCH;
                }

                chomp($err = $exception);
            }

            my $p2p_prefix = $method =~ tr/_/./;

            if (my $message = $ERROR_MAP{$err}) {
                stats_inc($p2p_prefix . '.error', {tags => ['error_code:' . $err]});
                if ($err =~ /^BI[0-9]+$/) {
                    $log->warnf("P2P %s failed, DB failure: %s, original: %s", $method, $err, $exception->[1])
                        ;    # original DB error may have useful details
                    $err = 'P2PError';    # hide db error codes from user
                }
                return BOM::RPC::v3::Utility::create_error({
                    code              => $err,
                    message_to_client => localize($message, (ref($err_params) eq 'ARRAY' ? $err_params : [])->@*),
                    (ref($err_details) eq 'HASH' ? (details => $err_details) : ()),
                });
            } else {
                # This indicates a bug in the code.
                $log->warnf("Unexpected error in P2P %s: %s, please report as a bug to backend", $method, $err);
                stats_inc($p2p_prefix . '.error', {tags => ['error_code:unknown']});
                return BOM::RPC::v3::Utility::create_error({
                    code              => 'P2PError',
                    message_to_client => localize('Sorry, an error occurred.')    #
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
    my $name   = $args{params}{args}{name};
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

    my $agent = $client->p2p_agent_update($args{params}{args}->%*) // die "AgentNotRegistered\n";

    return _agent_details($agent);
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
    my $agent;

    if (exists $args{params}{args}{agent_id}) {
        $agent = $client->p2p_agent_list(id => $args{params}{args}{agent_id})->[0] // die "AgentNotFound\n";
    } else {
        $agent = $client->p2p_agent // die "AgentNotFound\n";
    }

    return _agent_details($agent);
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
    my $offer  = $client->p2p_offer_create($args{params}{args}->%*);

    return _offer_details($offer);
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
    my $offer = $client->p2p_offer($args{params}{args}{offer_id}) // die "OfferNotFound\n";

    return _offer_details($offer);
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
    my $amount = $args{params}{args}{amount} // 1;

    my $list = $client->p2p_offer_list($args{params}{args}->%*);
    my @offers = map { _offer_details($_, $amount) } @$list;

    return {list => \@offers};
};

=head2 p2p_offer_update

Modifies details on an offer.

=cut

p2p_rpc p2p_offer_update => sub {
    my %args = @_;

    my $client = $args{client};
    my $offer = $client->p2p_offer_update($args{params}{args}->%*) // die "OfferNotFound\n";
    return _offer_details($offer);
};

=head2 p2p_order_create

Creates a new order for an offer.

=cut

p2p_rpc p2p_order_create => sub {
    my %args = @_;

    my $client = $args{client};

    my $order = $client->p2p_order_create($args{params}{args}->%*, source => $args{params}{source});

    my $order_response = _order_details($client, $order);

    BOM::Platform::Event::Emitter::emit(
        p2p_order_created => {
            client_loginid => $client->loginid,
            order_id       => $order->{order_id},
        });

    return $order_response;
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

    my $list = $client->p2p_order_list(%{$args{params}{args}}{grep { exists $args{params}{args}{$_} } qw(status agent_id offer_id limit offset)});

    my @orders = map { _order_details($client, $_) } @{$list};

    return {list => \@orders};
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

    my $order = $client->p2p_order($params->{args}{order_id});

    my $order_response = _order_details($client, $order);

    return $order_response;
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
        id     => $order_id,
        source => $params->{source});

    BOM::Platform::Event::Emitter::emit(
        p2p_order_updated => {
            client_loginid => $client->loginid,
            order_id       => $order->{order_id},
        });

    return {
        order_id => $order_id,
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
        id     => $order_id,
        source => $params->{source});

    BOM::Platform::Event::Emitter::emit(
        p2p_order_updated => {
            client_loginid => $client->loginid,
            order_id       => $order->{order_id},
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
    die "PermissionDenied\n";
};

sub _agent_details {
    my ($agent) = @_;

    return +{
        agent_id         => $agent->{id},
        agent_name       => $agent->{name},
        client_loginid   => $agent->{client_loginid},
        created_time     => Date::Utility->new($agent->{created_time})->epoch,
        is_active        => $agent->{is_active},
        is_authenticated => $agent->{is_authenticated},
    };
}

sub _offer_details {
    my ($offer, $amount) = @_;

    $offer->{amount} = financialrounding('amount', $offer->{account_currency}, $offer->{offer_amount});
    $offer->{amount_display} = formatnumber('amount', $offer->{account_currency}, $offer->{offer_amount});
    $offer->{amount_used} = financialrounding('amount', $offer->{account_currency}, $offer->{offer_amount} - $offer->{remaining});
    $offer->{amount_used_display} = formatnumber('amount', $offer->{account_currency}, $offer->{offer_amount} - $offer->{remaining});
    $offer->{max_amount} = financialrounding('amount', $offer->{account_currency}, $offer->{max_amount});
    $offer->{max_amount_display} = formatnumber('amount', $offer->{account_currency}, $offer->{max_amount});
    $offer->{min_amount} = financialrounding('amount', $offer->{account_currency}, $offer->{min_amount});
    $offer->{min_amount_display} = formatnumber('amount', $offer->{account_currency}, $offer->{min_amount});
    $offer->{rate} = financialrounding('amount', $offer->{local_currency}, $offer->{rate});
    $offer->{rate_display} = formatnumber('amount', $offer->{local_currency}, $offer->{rate});
    $offer->{price} = financialrounding('amount', $offer->{local_currency}, $offer->{rate} * ($amount // 1));
    $offer->{price_display} = formatnumber('amount', $offer->{local_currency}, $offer->{rate} * ($amount // 1));
    $offer->{created_time} = Date::Utility->new($offer->{created_time})->epoch;
    $offer->{offer_description} //= '';

    delete @$offer{qw(remaining offer_amount)};

    return $offer;
}

sub _order_details {
    my ($client, $order) = @_;

    $order->{type} = delete $order->{offer_type};
    $order->{account_currency} //= delete $order->{offer_account_currency};
    $order->{local_currency}   //= delete $order->{offer_local_currency};

    $order->{amount} = financialrounding('amount', $order->{account_currency}, $order->{order_amount});
    $order->{amount_display} = formatnumber('amount', $order->{account_currency}, $order->{order_amount});
    $order->{expiry_time}    = Date::Utility->new($order->{expire_time})->epoch;
    $order->{created_time}   = Date::Utility->new($order->{created_time})->epoch;
    $order->{rate}           = financialrounding('amount', $order->{local_currency}, $order->{offer_rate});
    $order->{rate_display}   = formatnumber('amount', $order->{local_currency}, $order->{offer_rate});
    $order->{price}          = financialrounding('amount', $order->{local_currency}, $order->{offer_rate} * $order->{order_amount});
    $order->{price_display}  = formatnumber('amount', $order->{local_currency}, $order->{offer_rate} * $order->{order_amount});
    $order->{offer_description} //= '';
    $order->{order_description} //= '';

    delete @$order{
        qw(order_amount offer_rate is_expired client_balance client_confirmed client_loginid client_trans_id escrow_trans_id offer_remaining expire_time)
    };

    return $order;
}

1;
