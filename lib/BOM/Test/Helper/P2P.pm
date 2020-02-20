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

        $current_escrow = create_client();
        BOM::Config::Runtime->instance->app_config->payments->p2p->escrow([$current_escrow->loginid]);
        return $current_escrow;
    }

    sub reset_escrow {
        undef $current_escrow;
        BOM::Config::Runtime->instance->app_config->payments->p2p->escrow($original_escrow);
        return;
    }
}

sub create_advertiser {
    my %param = @_;

    my $balance = $param{balance} // 0;

    my $advertiser = create_client($balance);

    $advertiser->p2p_advertiser_create($param{name} // 'test advertiser');

    $advertiser->account('USD');

    $advertiser->p2p_advertiser_update(is_approved => 1);

    return $advertiser;
}

sub create_client {
    my $balance = shift // 0;
    my $client = BOM::Test::Helper::Client::create_client();
    $client->account('USD');

    if ($balance) {
        BOM::Test::Helper::Client::top_up($client, $client->currency, $balance);
    }

    return $client;
}

sub create_advert {
    my %param = @_;

    $param{amount}           //= 100;
    $param{description}      //= 'Test advert';
    $param{type}             //= 'buy';
    $param{rate}             //= 1;
    $param{balance}          //= $param{type} eq 'sell' ? $param{amount} : 0;
    $param{min_order_amount} //= 0.1;
    $param{max_order_amount} //= 100;
    $param{payment_method}   //= 'bank_transfer';

    my $advertiser = create_advertiser(balance => $param{balance});

    my $advert = $advertiser->p2p_advert_create(%param);

    return $advertiser, $advert;
}

sub create_order {
    my %param = @_;

    my $advert_id = $param{advert_id} || croak 'advert_id is required';
    my $amount      = $param{amount}      // 100;
    my $expiry      = $param{expiry}      // 7200;
    my $description = $param{description} // 'Test order';
    my $balance     = $param{balance};

    my $client = create_client($balance);

    my $order = $client->p2p_order_create(
        advert_id   => $advert_id,
        amount      => $amount,
        expiry      => $expiry,
        description => $description
    );

    return $client, $order;
}

sub expire_order {
    my ($client, $order_id) = @_;

    return $client->db->dbic->dbh->do("UPDATE p2p.p2p_order SET expire_time = NOW() - INTERVAL '1 day' WHERE id = $order_id");
}

sub set_order_status {
    my ($client, $order_id, $new_status) = @_;

    return $client->db->dbic->dbh->do('SELECT * FROM p2p.order_update(?, ?)', undef, $order_id, $new_status);
}

1;
