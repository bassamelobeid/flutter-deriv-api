package BOM::Test::Helper::P2P;

use strict;
use warnings;

use BOM::Test::Helper::Client;
use BOM::User;
use BOM::Config;
use Carp;
use Test::More;
use Test::MockModule;

my $advertiser_num;
my $client_num;
my $mock_sb;
my $mock_sb_user;

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

sub create_advertiser {
    my %param = @_;

    $param{balance}     //= 0;
    $param{name}        //= 'test advertiser ' . (++$advertiser_num);
    $param{currency}    //= 'USD';
    $param{is_approved} //= 1;

    $param{client_details}{email} //= 'p2p_' . (++$client_num) . '@binary.com';
    my $client = BOM::Test::Helper::Client::create_client(undef, undef, $param{client_details});

    BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);

    $client->account($param{currency});

    if ($param{balance}) {
        BOM::Test::Helper::Client::top_up($client, $client->currency, $param{balance});
    }

    $client->p2p_advertiser_create(name => $param{name});
    $client->p2p_advertiser_update(is_approved => $param{is_approved});

    return $client;
}

sub create_advert {
    my %param = @_;

    $param{amount}           //= 100;
    $param{description}      //= 'Test advert';
    $param{type}             //= 'sell';
    $param{rate}             //= 1;
    $param{min_order_amount} //= 0.1;
    $param{max_order_amount} //= 100;
    $param{payment_method}   //= 'bank_transfer';
    $param{local_currency}   //= 'myr';

    $param{payment_info} //= $param{type} eq 'sell' ? 'Bank: 123456' : undef;
    $param{contact_info} //= $param{type} eq 'sell' ? 'Tel: 123456'  : undef;

    my $advertiser = $param{client} // create_advertiser(
        balance        => $param{type} eq 'sell' ? $param{amount} : 0,
        client_details => $param{advertiser},
    );

    my $advert = $advertiser->p2p_advert_create(%param);

    return $advertiser, $advert;
}

sub create_order {
    my %param = @_;

    my $advert_id = $param{advert_id} || croak 'advert_id is required';
    my $amount    = $param{amount}  // 100;
    my $expiry    = $param{expiry}  // 7200;
    my $balance   = $param{balance} // $param{amount};
    my $client    = $param{client}  // create_advertiser(balance => $balance);

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
    my ($client, $order_id, $interval) = @_;
    $interval //= '-1 day';

    return $client->db->dbic->dbh->do("UPDATE p2p.p2p_order SET expire_time = NOW() + INTERVAL '$interval' WHERE id = $order_id");
}

sub ready_to_refund {
    my ($client, $order_id, $days_needed) = @_;
    $days_needed //= BOM::Config::Runtime->instance->app_config->payments->p2p->refund_timeout;

    return $client->db->dbic->dbh->do("UPDATE p2p.p2p_order SET status='timed-out', expire_time = NOW() - INTERVAL ? WHERE id = ?",
        undef, sprintf('%d days', $days_needed), $order_id);
}

sub set_order_status {
    my ($client, $order_id, $new_status) = @_;

    $client->db->dbic->dbh->do(
        "UPDATE p2p.p2p_advert a SET active_orders=active_orders+
        CASE 
            WHEN p2p.is_status_final(?) AND NOT p2p.is_status_final(o.status) THEN -1
            WHEN NOT p2p.is_status_final(?) AND p2p.is_status_final(o.status) THEN 1
            ELSE 0
        END
        FROM p2p.p2p_order o WHERE o.advert_id = a.id AND o.id = ?",
        undef, $new_status, $new_status, $order_id
    );

    $client->db->dbic->dbh->do('SELECT * FROM p2p.order_update(?, ?)', undef, $order_id, $new_status);
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

=head2 set_order_disputable

Given a p2p order, it updates any requirement needed to be ready for dispute.

=cut

sub set_order_disputable {
    my ($client, $order_id) = @_;

    expire_order($client, $order_id);

    # Status needs to be `timed-out`
    $client->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM p2p.order_update(?, ?)', undef, $order_id, 'timed-out');
        });
}

1;
