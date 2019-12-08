package BOM::User::Client::OTC;

use strict;
use warnings;

use feature 'state';

use Exporter qw(import);
use BOM::Config::Runtime;
use Future::Exception;
use Carp;
use List::Util qw(any);
use Syntax::Keyword::Try;
use ExchangeRates::CurrencyConverter qw(in_usd);

our @EXPORT_OK = qw(
    new_otc_agent
    get_otc_agent
    get_otc_agent_list
    update_otc_agent
    create_otc_offer
    get_otc_offer
    get_otc_offer_list
    update_otc_offer
    create_otc_order
    get_otc_order
    get_otc_order_list
    confirm_otc_order
    cancel_otc_order
    get_escrow
);

use constant MAXIMUM_ACTIVE_OFFERS => 10;

=head1 DESCRIPTION

This package is a role for BOM::User::Client, which provides methods to client object
for working with OTC agents, offers and orders.

Every new public method in this package should be explicitly exported
and after that explicitly imported to BOM::User::Client.

=head2 new_otc_agent

    Attempts to register client as an agent.
    Returns the agent info or dies with error code.

=cut

sub new_otc_agent {
    my ($client, $agent_name) = @_;

    die "AlreadyRegistered\n" if $client->get_otc_agent;

    return $client->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM otc.agent_create(?, ?)', undef, $client->loginid, $agent_name // '');
        });
}

=head2 get_otc_agent

    Returns agent info of client.

=cut

sub get_otc_agent {
    my $client = shift;
    return $client->get_otc_agent_list(loginid => $client->loginid);
}

=head2 get_otc_agent_list

    Returns a list of agents filtered by id and/or loginid.

=cut

sub get_otc_agent_list {
    my ($client, %param) = @_;

    return $client->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM otc.agent_list(?, ?)', undef, @param{qw/id loginid/});
        });
}

=head2 update_otc_agent

    Updates the client agent info with fields in %param.
    Returns latest agent info.

=cut

sub update_otc_agent {
    my ($client, %param) = @_;

    my $agent_info = $client->get_otc_agent // return;

    return $client->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM otc.agent_update(?, ?, ?, ?)', undef, $agent_info->{id}, @param{qw/auth active name/});
        });
}

=head2 create_otc_offer

    Creates an offer with %param with client as agent.
    Returns new offer or dies with error code.

=cut

sub create_otc_offer {
    my ($client, %param) = @_;

    my $agent_info = $client->get_otc_agent;
    die "AgentNotActive\n" unless $agent_info && $agent_info->{is_active};
    die "AgentNotAuthenticated\n" unless $agent_info->{is_authenticated};
    die "InvalidOfferCurrency\n" if !$param{currency} || uc($param{currency}) ne $client->currency;
    die "MaximumExceeded\n"
        if in_usd($param{amount}, uc $param{currency}) > BOM::Config::Runtime->instance->app_config->payments->otc->limits->maximum_offer;

    my $active_offers_count = $client->get_otc_offer_list(
        loginid         => $client->binary_user_id,
        active          => 1,
        include_expired => 0,
    )->@*;
    die "OfferMaxExceeded\n" if $active_offers_count >= MAXIMUM_ACTIVE_OFFERS;

    $param{country} //= $client->residence;

    return $client->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM otc.offer_create(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                undef, $agent_info->{id}, @param{qw/type currency expiry amount price min_amount max_amount method description country/});
        });
}

=head2 get_otc_offer

    Get a single offer by $id.

=cut

sub get_otc_offer {
    my ($client, $id) = @_;
    return undef unless $id;
    return $client->get_otc_offer_list(
        id              => $id,
        include_expired => 1
    )->[0];
}

=head2 get_otc_offer_list

    Get offers filtered by %param.
    Expired offers are excluded by default.

=cut

sub get_otc_offer_list {
    my ($client, %param) = @_;

    return $client->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                'SELECT * FROM otc.offer_list(?, ?, ?, ?, ?, ?)',
                {Slice => {}},
                @param{qw/id currency loginid active type include_expired/});
        });
}

=head2 update_otc_offer

    Updates the offer of $param{id} with fields in %param.
    Expired offers cannot be updated.
    If the sum of all outstanding order exceeds the offer amount, no fields can be changed except for is_active.
    Returns latest offer info or dies with error code.

=cut

sub update_otc_offer {
    my ($client, %param) = @_;

    my $offer_id = delete $param{id};
    my $offer = $client->get_otc_offer($offer_id) // return;
    die "OfferNoEditExpired\n" if $offer->{is_expired};
    # no edits are allowed when there is no remaining amount, except for deactivate/activate
    if (any { $_ ne 'active' && defined $param{$_} } keys %param) {
        die "OfferNoEditInactive\n" unless $offer->{is_active};
        my $amount = $param{amount} // $offer->{amount};
        die "OfferNoEditAmount\n" unless $amount > $offer->{amount_used};
    }
    die "MaximumExceeded\n"
        if $param{amount}
        && in_usd($param{amount}, $offer->{currency}) > BOM::Config::Runtime->instance->app_config->payments->otc->limits->maximum_offer;

    return $client->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM otc.offer_update(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                undef, $offer_id, @param{qw/active type currency expiry amount price min_amount max_amount method description country/});
        });
}

=head2 create_otc_order

    Creates an order for offer $param{offer_id} with %param for client.
    Offer and agent must be valid.
    Only one active order per offer per client is allowed.
    Returns new order or dies with error code.
    This will move funds from agent to escrow.

=cut

sub create_otc_order {
    my ($client, %param) = @_;

    my ($offer_id, $amount, $description, $source) = @param{qw/offer_id amount description source/};

    my $offer_info = $client->get_otc_offer($offer_id);

    die "OfferIsDisabled\n" unless $offer_info->{is_active};

    die "InvalidOfferExpired\n" if $offer_info->{is_expired};

    die "InvalidCurrency\n" unless $offer_info->{currency} eq $client->currency;

    die "InvalidOfferOwn\n" if $offer_info->{agent_loginid} eq $client->loginid;

    die "InvalidAmount\n" unless $amount > 0 && ($offer_info->{amount} - $offer_info->{amount_used}) >= $amount;

    die "MaximumExceeded\n"
        if in_usd($amount, $offer_info->{currency}) > BOM::Config::Runtime->instance->app_config->payments->otc->limits->maximum_order;

    my $agent_info = $client->get_otc_agent_list(id => $offer_info->{agent_id});
    die "OTC Agent isn't found $offer_info->{agent_id}" unless $agent_info;

    die "OfferOwnerNotAuthenticated\n" unless $agent_info->{is_authenticated} && $agent_info->{is_active};

    my $escrow = $client->get_escrow;

    die "EscrowNotFound\n" unless $escrow;

    my $open_orders = $client->get_otc_order_list(
        offer_id => $offer_id,
        loginid  => $client->loginid,
        status   => ['pending', 'client-confirmed']);

    die "OrderAlreadyExists\n" if @{$open_orders};

    return $client->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM otc.order_create(?, ?, ?, ?, ?, ?, ?)',
                undef, $offer_id, $client->loginid, $escrow->loginid, $amount, $description, $source, $client->loginid);
        });
}

=head2 get_otc_order

    Get a single order by $id.

=cut

sub get_otc_order {
    my ($client, $id) = @_;
    return undef unless $id;
    return $client->get_otc_order_list(id => $id)->[0];
}

=head2 get_otc_order_list

    Get orders filtered by %param.
    $param{loginid} will match on offer agent loginid or order client loginid.
    $param{status} if provided must by an arrayref.

=cut

sub get_otc_order_list {
    my ($client, %param) = @_;

    croak 'Invalid status format'
        if defined $param{status}
        && ref $param{status} ne 'ARRAY';

    return $client->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT * FROM otc.order_list(?, ?, ?, ?)', {Slice => {}}, @param{qw/id offer_id loginid status/});
        }) // [];
}

=head2 confirm_otc_order

    Confirms the order of $param{id} and returns updated order.
    If client is the agent, order will be agent confirmed and order will be completed, moving funds from escrow to client.
    If client is the client, order will be client confirmed.
    Otherwise dies with error code.

=cut

sub confirm_otc_order {
    my ($client, %param) = @_;

    state $confirmation_handlers = {
        client => \&_client_confirmation,
        agent  => \&_agent_confirmation,
    };

    my $order_info = $client->get_otc_order($param{id});
    die "OrderNotFound\n" unless $order_info;

    my $ownership_type = _order_ownership_type($client, $order_info);

    die "PermissionDenied\n" unless $confirmation_handlers->{$ownership_type};

    return $confirmation_handlers->{$ownership_type}->($client, $order_info, $param{source});
}

=head2 cancel_otc_order

    Cancels the order of $param{id}.
    Order must belong to client.
    This will move funds from escrow to agent.

=cut

sub cancel_otc_order {
    my ($client, %param) = @_;

    my $order_info = $client->get_otc_order($param{id});
    die "OrderNotFound\n" unless $order_info;

    my $ownership_type = _order_ownership_type($client, $order_info);

    die "PermissionDenied\n" unless $ownership_type eq 'client';

    my $escrow = $client->get_escrow;

    return $client->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM otc.order_cancel(?, ?, ?, ?)',
                undef, $order_info->{id}, $escrow->loginid, $param{source}, $client->loginid);
        });
}

=head2 get_escrow

    Gets the configured escrow account for clients currency and landing company.

=cut

sub get_escrow {
    my ($client) = @_;
    my ($broker, $currency) = ($client->broker_code, $client->currency);
    my @escrow_list = BOM::Config::Runtime->instance->app_config->payments->otc->escrow->@*;
    require BOM::User::Client;
    for my $loginid (@escrow_list) {
        try {
            my $escrow_account = BOM::User::Client->new({loginid => $loginid});
            return undef unless $escrow_account;
            return undef unless $escrow_account->broker eq $broker;
            return undef unless $escrow_account->currency eq $currency;
            return $escrow_account;
        }
        catch {
            return undef;
        };
    }

    return undef;
}

=head1 Private methods

=head2 _order_ownership_type

    Returns whether client is the agent or client of the order.

=cut

sub _order_ownership_type {
    my ($client, $order_info) = @_;

    return 'client' if $order_info->{client_loginid} eq $client->loginid;

    return 'agent' if $order_info->{agent_loginid} eq $client->loginid;

    return '';
}

=head2 _client_confirmation

    Sets order client confirmed.

=cut

sub _client_confirmation {
    my ($client, $order_info) = @_;

    die "InvalidStateForClientConfirmation\n" if $order_info->{status} ne 'pending';

    return $client->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM otc.order_confirm_client(?, ?)', undef, $order_info->{id}, 1);
        });
}

=head2 _agent_confirmation

    Sets order agent_confirmed and completes the order in a single transcation.
    Completing the order moves funds from escrow to client.

=cut

sub _agent_confirmation {
    my ($client, $order_info, $source) = @_;

    die "InvalidStateForAgentConfirmation\n" if $order_info->{status} ne 'client-confirmed';

    my $escrow = $client->get_escrow;

    return $client->db->dbic->txn(
        fixup => sub {
            $_->do('SELECT * FROM otc.order_confirm_agent(?, ?)', undef, $order_info->{id}, 1);
            return $_->selectrow_hashref('SELECT * FROM otc.order_complete(?, ?, ?, ?)',
                undef, $order_info->{id}, $escrow->loginid, $source, $client->loginid,);
        });
}

1;
