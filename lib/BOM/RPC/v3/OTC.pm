package BOM::RPC::v3::OTC;

=head1 NAME

BOM::RPC::v3::OTC - peer-to-peer "over-the-counter" payment support

=head1 DESCRIPTION

The OTC cashier is a system which allows buyers and sellers to handle the details
of payments outside our system. It acts as a marketplace for offers and orders.

=cut

use strict;
use warnings;

use JSON::MaybeUTF8 qw(:v1);
use DataDog::DogStatsd::Helper qw(stats_inc);

use BOM::User::Client;
use BOM::Platform::Context qw (localize request);
use BOM::Config;
use BOM::Config::Runtime;
use BOM::User;
use Try::Tiny;

use BOM::RPC::Registry '-dsl';

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

# Standard error codes for any OTC calls.
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
        OTCDisabled          => localize('The OTC cashier is currently disabled'),
        RestrictedCountry    => localize('This country is not enabled for OTC cashier functionality'),
        RestrictedCurrency   => localize('This currency is not enabled for OTC cashier functionality'),
        UnavailableOnVirtual => localize('OTC cashier functionality is not available on demo accounts'),
        # Client status
        NotLoggedIn      => localize('You are not logged in'),
        NoCurrency       => localize('You have not yet selected a currency for your account'),
        PermissionDenied => localize('You do not have permission for this action'),
        NotRegistered    => localize('You are not yet registered as an OTC agent'),
        # Invalid data
        InvalidPaymentMethod => localize('This payment method is invalid'),
        NotFound             => localize('Not found'),
        MinimumNotMet        => localize('The minimum amount requirements are not met'),
        MaximumExceeded      => localize('This is above the maximum limit'),
        AlreadyInProgress    => localize('This cannot be cancelled since the order is already in progress'),

        InvalidAmount => localize('Invalid amount for creating an order'),
        # bom-user errors
        AgentNotFound         => localize('OTC Agent not found'),
        AgentNotRegistered    => localize('This account is not registered as an OTC agent'),
        AgentNotActive        => localize('The provided agent ID does not belong to an active agent'),
        AgentNotAuthenticated => localize('The agent is not authenticated'),
        OfferNoEditExpired    => localize('The offer is expired and cannot be changed.'),
        OfferNoEditInactive   => localize('The offer is inactive and cannot be changed.'),
        OfferNotFound         => localize('Offer not found'),
        OfferNoEditAmount     => localize('The offer has no available amount and cannot be changed.'),
        OfferMaxExceeded      => localize('The maximum limit of active offers reached.'),
        InvalidOfferCurrency  => localize('Invalid offer currency'),
        OrderNotFound         => localize('Order not found'),
        InvalidOfferOwn       => localize('You cannot create an order for your own offer.'),
        InvalidOfferExpired   => localize('The offer has expired.'),
        # DB errors
        BI225 => localize('Offer not found'),
        BI226 => localize('Cannot create order for your own offer'),
        BI227 => localize('Insufficient funds in account'),
        BI228 => localize('Order not found'),
        BI229 => localize('Order cannot be completed in its current state'),
        BI230 => localize('Order has not been confirmed by agent'),
        BI231 => localize('Order not found'),
        BI232 => localize('Order cannot be cancelled in its current state'),
        BI233 => localize('Order not found'),
        BI234 => localize('Order cannot be agent confirmed in its current state'),
        BI235 => localize('Order not found'),
        BI236 => localize('Order cannot be client confirmed in its current state'),
        BI237 => localize('Order currency is different from account currency'),
    );
};

=head2 otc_rpc

Helper function for wrapping error handling around our OTC-related RPC calls.

Takes the following parameters:

=over 4

=item * C<$method> - which method to expose, e.g. C<otc_order_create>

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

 otc_rpc otc_order_create => sub { create_order($client, $params->{amount}) };

=cut

sub otc_rpc {
    my ($method, $code) = @_;
    return rpc $method => category => 'otc',
        sub {
        my $params = shift;
        try {
            my $app_config = BOM::Config::Runtime->instance->app_config;

            # Yes, we have two ways to disable - devops can shut it down if there
            # are problems, and payments/ops/QA can choose whether or not the
            # functionality should be exposed in the first place. The ->otc->enabled
            # check may be dropped in future once this is stable.
            die "OTCDisabled\n" if $app_config->system->suspend->otc;
            die "OTCDisabled\n" unless $app_config->payments->otc->enabled;

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
            my $err;
            # db errors come as [ BIxxx, message ]
            # bom-user errors come as a string "ErrorCode\n"
            if (ref eq 'ARRAY') {
                $err = $_->[0];
            } else {
                chomp($err = $_);
            }
            my $otc_prefix = $method =~ tr/_/./;

            if (my $message = $ERROR_MAP{$err}) {
                stats_inc($otc_prefix . '.error', {tags => ['error_code:' . $err]});
                if ($err =~ /^BI\d\d\d$/) {
                    warn "OTC $method failed, DB failure: $err, original: " . $_->[1];    # original DB error may have useful details
                    $err = 'OTCError';                                                    # hide db error codes from user
                }
                return BOM::RPC::v3::Utility::create_error({
                        code              => $err,
                        message_to_client => localize($message)});
            } else {
                # This indicates a bug in the code.
                warn "Unexpected error in OTC $method: $err, please report as a bug to backend";
                stats_inc($otc_prefix . '.error', {tags => ['error_code:unknown']});
                return BOM::RPC::v3::Utility::create_error({
                        code              => 'OTCError',
                        message_to_client => localize('Sorry, an error occurred.')});
            }
        }
        };
}

=head2 otc_agent_register

Requests registration for an agent account.

Each client is able to have at most one agent account.

=cut

otc_rpc otc_agent_register => sub {
    my (%args) = @_;
    my $client = $args{client};
    my $name   = $args{params}{args}{name};
    $client->new_otc_agent($name);
    return {'otc_agent_status' => 'pending'};
};

=head2 otc_agent_update

Update agent details - default comment, name etc.

=cut

otc_rpc otc_agent_update => sub {
    my (%args) = @_;
    my $client = $args{client};
    return $client->update_otc_agent($args{params}{args}->%*) // die "AgentNotRegistered\n";
};

=head2 otc_agent_info

Returns information about the given agent (by ID).

=cut

otc_rpc otc_agent_info => sub {
    my (%args)   = @_;
    my $client   = $args{client};
    my $agent_id = $args{params}{args}{agent};
    return $client->get_otc_agent_list(id => $agent_id) // die "AgentNotFound\n";
};

=head2 otc_offer_create

Attempts to create a new offer.

=cut

otc_rpc otc_offer_create => sub {
    my (%args) = @_;
    my $client = $args{client};
    return $client->create_otc_offer($args{params}{args}->%*);
};

=head2 otc_offer_info

Returns information about an offer.

=cut

otc_rpc otc_offer_info => sub {
    my (%args) = @_;
    my $client = $args{client};
    return $client->get_otc_offer($args{params}{args}{id}) // die "OfferNotFound\n";
};

=head2 otc_method_list

Returns a list of all available payment methods.

=cut

otc_rpc otc_method_list => sub {
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

=head2 otc_offer_list

Returns available offers.

=cut

otc_rpc otc_offer_list => sub {
    my %args = @_;

    my $client = $args{client};
    return $client->get_otc_offer_list($args{params}{args}->%*);
};

=head2 otc_offer_edit

Modifies details on an offer.

Typically used to cancel or confirm.

=cut

otc_rpc otc_offer_edit => sub {
    my %args = @_;

    my $client = $args{client};
    return $client->update_otc_offer($args{params}{args}->%*) // die "OfferNotFound\n";
};

=head2 otc_offer_remove

Removes an offer entirely.

=cut

otc_rpc otc_offer_remove => sub {
    my %args = @_;

    my ($client, $params) = @args{qw/client params/};
    return $client->update_otc_offer(
        id     => $params->{args}{id},
        active => 0
    ) // die "OfferNotFound\n";
};

=head2 otc_order_create

Creates a new order for an offer.

=cut

otc_rpc otc_order_create => sub {
    my %args = @_;

    my $client = $args{client};
    my $order  = $client->create_otc_order($args{params}{args}->%*);

    BOM::Platform::Event::Emitter::emit(otc_offer_created => $order);

    return $order;
};

=head2 otc_order_list

Lists orders.

=over 4

=item * status

=back

=cut

otc_rpc otc_order_list => sub {
    my %args = @_;

    my $client = $args{client};

    return $client->get_order_list(status => $args{params}{status});
};

=head2 otc_order_confirm

Shortcut for updating order status to C<confirmed>.

=over 4

=item * id - otc order id

=back

=cut

otc_rpc otc_order_confirm => sub {
    my %args = @_;

    my ($client, $params) = @args{qw/client params/};

    my $order = $client->confirm_otc_order(
        id     => $params->{args}{id},
        source => $params->{source});

    BOM::Platform::Event::Emitter::emit(otc_order_updated => $order);

    return $order;
};

=head2 otc_order_cancel

Shortcut for updating order status to C<cancelled>.


=over 4

=item * id - otc order id

=back

=cut

otc_rpc otc_order_cancel => sub {
    my %args = @_;

    my ($client, $params) = @args{qw/client params/};

    my $order = $client->cancel_otc_order(
        id     => $params->{args}{id},
        source => $params->{source});

    BOM::Platform::Event::Emitter::emit(otc_order_updated => $order);

    return $order;
};

=head2 otc_order_chat

Exchange chat messages.

=cut

otc_rpc otc_order_chat => sub {
    die "PermissionDenied\n";
};

1;
