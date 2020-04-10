package BOM::Test::Helper::P2P;

use strict;
use warnings;

use BOM::Test::Helper::Client;
use Carp;
use Test::More;
use Test::MockModule;

my $advertiser_num;
my $mock_sb;
my $mock_sb_user;

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

    $advertiser->p2p_advertiser_create(name => $param{name} // 'test advertiser ' . (++$advertiser_num));

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
    $param{type}             //= 'sell';
    $param{rate}             //= 1;
    $param{balance}          //= $param{type} eq 'sell' ? $param{amount} : 0;
    $param{min_order_amount} //= 0.1;
    $param{max_order_amount} //= 100;
    $param{payment_method}   //= 'bank_transfer';
    $param{local_currency}   //= 'myr';

    $param{payment_info} //= $param{type} eq 'sell' ? 'Bank: 123456' : undef;
    $param{contact_info} //= $param{type} eq 'sell' ? 'Tel: 123456'  : undef;

    my $advertiser = create_advertiser(balance => $param{balance});

    my $advert = $advertiser->p2p_advert_create(%param);

    return $advertiser, $advert;
}

sub create_order {
    my %param = @_;

    my $advert_id = $param{advert_id} || croak 'advert_id is required';
    my $amount  = $param{amount}  // 100;
    my $expiry  = $param{expiry}  // 7200;
    my $balance = $param{balance} // $param{amount};
    my $client  = $param{client}  // create_client($balance);

    my $advert = $client->p2p_advert_info(id => $param{advert_id});

    $param{payment_info} //= $advert->{type} eq 'buy' ? 'Bank: 123456' : undef;
    $param{contact_info} //= $advert->{type} eq 'buy' ? 'Tel: 123456'  : undef;

    my $order = $client->p2p_order_create(
        advert_id    => $advert_id,
        amount       => $amount,
        expiry       => $expiry,
        payment_info => $param{payment_info},
        contact_info => $param{contact_info},
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

sub bypass_sendbird {
    $mock_sb      = Test::MockModule->new('WebService::SendBird');
    $mock_sb_user = Test::MockModule->new('WebService::SendBird::User');

    $mock_sb->mock(
        'create_user',
        sub {
            note "mocking sendbird create_user";
            return WebService::SendBird::User->new(
                api_client     => 1,
                user_id        => 'dummy',
                session_tokens => [{
                        'session_token' => 'dummy',
                        'expires_at'    => (time + 7200) * 1000,
                    }]);
        });

    $mock_sb->mock(
        'create_group_chat',
        sub {
            note "mocking sendbird create_group_chat";
            return WebService::SendBird::GroupChat->new(
                api_client  => 1,
                channel_url => 'dummy',
            );
        });

    $mock_sb_user->mock(
        'issue_session_token',
        sub {
            note "mocking sendbird issue_session_token";
            return {
                'session_token' => 'dummy',
                'expires_at'    => (time + 7200) * 1000,
            };
        });
}

1;
