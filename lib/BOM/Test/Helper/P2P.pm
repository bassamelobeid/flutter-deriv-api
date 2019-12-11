package BOM::Test::Helper::P2P;

use strict;
use warnings;

use BOM::Test::Helper::Client;
use Carp;

{
    my ($current_escrow, $original_escrow);

    sub create_escrow {
        return $current_escrow if $current_escrow;

        $original_escrow = BOM::Config::Runtime->instance->app_config->payments->p2p->escrow;

        $current_escrow = BOM::Test::Helper::Client::create_client();
        $current_escrow->account('USD');
        BOM::Config::Runtime->instance->app_config->payments->p2p->escrow([$current_escrow->loginid]);
        return $current_escrow;
    }

    sub reset_escrow {
        undef $current_escrow;
        BOM::Config::Runtime->instance->app_config->payments->p2p->escrow($original_escrow);
        return;
    }
}

sub create_agent {
    my %param = @_;

    my $balance = $param{balance} // 0;

    my $agent = BOM::Test::Helper::Client::create_client();

    $agent->p2p_agent_create;

    $agent->account('USD');

    if ($balance) {
        BOM::Test::Helper::Client::top_up($agent, $agent->currency, $balance);
    }

    $agent->p2p_agent_update(auth => 1);

    return $agent;
}

sub create_client {
    my $client = BOM::Test::Helper::Client::create_client();
    $client->account('USD');

    return $client;
}

sub create_offer {
    my %param = @_;

    my $amount      = $param{amount}      // 100;
    my $description = $param{description} // 'Test offer';
    my $type        = $param{type}        // 'buy';
    my $currency    = $param{currency}    // 'USD';
    my $expiry      = $param{expiry}      // 30;

    my $agent = create_agent(balance => $amount);

    my $offer = $agent->p2p_offer_create(
        amount      => $amount,
        price       => $amount,
        description => $description,
        type        => $type,
        currency    => $currency,
        expiry      => $expiry
    );

    return $agent, $offer;
}

sub create_order {
    my %param = @_;

    my $offer_id = $param{offer_id} || croak 'offer_id is required';
    my $amount      = $param{amount}      // 100;
    my $description = $param{description} // 'Test order';

    my $client = create_client();

    my $order = $client->p2p_order_create(
        offer_id    => $offer_id,
        amount      => $amount,
        description => $description
    );

    return $client, $order;
}

sub expire_offer {
    my ($client, $offer_id) = @_;
    return $client->db->dbic->dbh->do("UPDATE p2p.p2p_offer SET expire_time = NOW() - INTERVAL '1 day' WHERE id = $offer_id");
}

sub set_order_status {
    my ($client, $order_id, $new_status) = @_;

    return $client->db->dbic->dbh->do('SELECT * FROM p2p.order_update(?, ?)', undef, $order_id, $new_status);
}

1;
