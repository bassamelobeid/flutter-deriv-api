use strict;
use warnings;

use Test::Fatal;
use Test::Deep;
use Test::More;
use Test::MockModule;
use BOM::Event::Actions::P2P;

use BOM::Test;
use Date::Utility;
use Time::Moment;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Config::Runtime;
use BOM::Database::ClientDB;
use BOM::Test::Helper::P2P;

BOM::Test::Helper::P2P::bypass_sendbird();

subtest 'move funds back (order type sell)' => sub {
    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my $amount = 100;
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount  => $amount,
        type    => 'sell',
        balance => 760,
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => $amount,
        balance   => 1000,
    );
    my $balances = {
        client     => $client->account->balance,
        advertiser => $advertiser->account->balance,
        escrow     => $escrow->account->balance,
    };

    BOM::Test::Helper::P2P::ready_to_refund($client, $order->{id});
    ok BOM::Event::Actions::P2P::timeout_refund({
            client_loginid => $client->loginid,
            order_id       => $order->{id},
        }
        ),
        'Event was successful';

    my $result = $client->p2p_order_info(id => $order->{id});
    is $result->{status}, 'refunded', 'The order has been refunded';
    cmp_ok($client->account->balance,     '==', $balances->{client},               'The client balance is not involved in this refund');
    cmp_ok($advertiser->account->balance, '==', $balances->{advertiser} + $amount, 'The advertiser got refunded it seems');
    cmp_ok($escrow->account->balance,     '==', $balances->{escrow} - $amount,     'Escrow balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'move funds back (order type buy)' => sub {
    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my $amount = 100;
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount  => $amount,
        type    => 'buy',
        balance => 980,
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => $amount,
        balance   => 560,
    );
    my $balances = {
        client     => $client->account->balance,
        advertiser => $advertiser->account->balance,
        escrow     => $escrow->account->balance,
    };

    BOM::Test::Helper::P2P::ready_to_refund($client, $order->{id});
    ok BOM::Event::Actions::P2P::timeout_refund({
            client_loginid => $client->loginid,
            order_id       => $order->{id},
        }
        ),
        'Event was successful';

    my $result = $client->p2p_order_info(id => $order->{id});
    is $result->{status}, 'refunded', 'The order has been refunded';
    cmp_ok($client->account->balance,     '==', $balances->{client} + $amount, 'The client got refunded it seems');
    cmp_ok($advertiser->account->balance, '==', $balances->{advertiser},       'The advertiser balance is not involved in this refund');
    cmp_ok($escrow->account->balance,     '==', $balances->{escrow} - $amount, 'Escrow balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'failing the refund' => sub {
    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my $amount = 100;
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount  => $amount,
        type    => 'buy',
        balance => 980,
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => $amount,
        balance   => 560,
    );
    my $balances = {
        client     => $client->account->balance,
        advertiser => $advertiser->account->balance,
        escrow     => $escrow->account->balance,
    };

    # Invalid order id
    BOM::Test::Helper::P2P::ready_to_refund($client, $order->{id});
    ok !BOM::Event::Actions::P2P::timeout_refund({
            client_loginid => $client->loginid,
            order_id       => $order->{id} * -1,
        }
        ),
        'Event was unsuccessful due to invalid order id';

    # Incorret status
    BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, 'cancelled');
    ok !BOM::Event::Actions::P2P::timeout_refund({
            client_loginid => $client->loginid,
            order_id       => $order->{id},
        }
        ),
        'Event was unsuccessful due to invalid status for refund';

    # Correct status but the order expired 1 day ago
    BOM::Test::Helper::P2P::expire_order($client, $order->{id});    # This set the expire time to 1 day ago
    BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, 'timed-out');
    ok !BOM::Event::Actions::P2P::timeout_refund({
            client_loginid => $client->loginid,
            order_id       => $order->{id},
        }
        ),
        'Event was unsuccessful due to time threshold not reached';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'segment tracking' => sub {
    my $emit_mock    = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my $p2p_mock     = Test::MockModule->new('BOM::Event::Actions::P2P');
    my $track_mock   = Test::MockModule->new('BOM::Event::Services::Track');
    my $mock_segment = Test::MockModule->new('WebService::Async::Segment::Customer');
    my @segment_args;
    my @emitted_events;
    my $track_args;
    my @track_event_args;

    $emit_mock->mock(
        'emit',
        sub {
            push @emitted_events, \@_;
            return 1;
        });

    $p2p_mock->mock(
        '_track_p2p_order_event',
        sub {
            $track_args = {@_};
            return $p2p_mock->original('_track_p2p_order_event')->(@_);
        });

    $track_mock->mock(
        'track_event',
        sub {
            # Note the event must fire two `track_events`, one for each party
            push @track_event_args, {@_};
            return $track_mock->original('track_event')->(@_);
        });

    $mock_segment->mock(
        'track',
        sub {
            push @segment_args, [@_];
            return $mock_segment->original('track')->(@_);
        });

    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my $amount = 100;
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount  => $amount,
        type    => 'sell',
        balance => 760,
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => $amount,
        balance   => 1000,
    );
    my $balances = {
        client     => $client->account->balance,
        advertiser => $advertiser->account->balance,
        escrow     => $escrow->account->balance,
    };

    @emitted_events = ();
    BOM::Test::Helper::P2P::ready_to_refund($client, $order->{id});
    ok BOM::Event::Actions::P2P::timeout_refund({
            client_loginid => $client->loginid,
            order_id       => $order->{id},
        }
        ),
        'Event was successful';

    my $update_expected = {
        p2p_order_updated => {
            client_loginid => $client->loginid,
            order_id       => $order->{id},
            order_event    => 'timeout_refund',
        }};

    cmp_deeply(
        \@emitted_events,
        bag([
                'p2p_order_updated',
                {
                    client_loginid => $client->loginid,
                    order_id       => $order->{id},
                    order_event    => 'timeout_refund',
                }
            ],
            [
                'p2p_advertiser_updated',
                {
                    client_loginid => $client->loginid,
                }
            ],
            [
                'p2p_advertiser_updated',
                {
                    client_loginid => $advertiser->loginid,
                }
            ],
        ),
        'expected events emitted for timeout refund'
    );

    # Call order updated event
    ok BOM::Event::Actions::P2P::order_updated($update_expected->{p2p_order_updated}), 'Order updated event was successful';

    # Check whether _track_p2p_order_event has the correct arguments
    is $track_args->{order_event}, 'timeout_refund', 'The order event is correct';
    is $track_args->{order}{id}, $order->{id}, 'The order id is correct';

    # Check whether the track_events are called
    is scalar @track_event_args, 2, 'Two track_event fired';

    my @expected_track_event_args = ({
            event      => 'p2p_order_timeout_refund',
            loginid    => $client->loginid,
            properties => {
                user_role        => 'buyer',
                order_type       => 'buy',
                seller_nickname  => '',
                order_id         => $order->{id},
                buyer_user_id    => $client->binary_user_id,
                seller_user_id   => $advertiser->binary_user_id,
                currency         => $order->{account_currency},
                loginid          => $client->loginid,
                exchange_rate    => $order->{rate_display},
                local_currency   => $order->{local_currency},
                buyer_nickname   => $order->{client_details}->{name}     // '',
                seller_nickname  => $order->{advertiser_details}->{name} // '',
                amount           => $order->{amount},
                order_created_at => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
            }
        },
        {
            event      => 'p2p_order_timeout_refund',
            loginid    => $advertiser->loginid,
            properties => {
                user_role        => 'seller',
                order_type       => 'buy',
                order_id         => $order->{id},
                buyer_user_id    => $client->binary_user_id,
                seller_user_id   => $advertiser->binary_user_id,
                currency         => $order->{account_currency},
                loginid          => $advertiser->loginid,
                exchange_rate    => $order->{rate_display},
                local_currency   => $order->{local_currency},
                buyer_nickname   => $order->{client_details}->{name}     // '',
                seller_nickname  => $order->{advertiser_details}->{name} // '',
                amount           => $order->{amount},
                order_created_at => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
            }});

    cmp_deeply $track_event_args[0], superhashof($expected_track_event_args[0]), 'Track event params are looking good for buyer';
    cmp_deeply $track_event_args[1], superhashof($expected_track_event_args[1]), 'Track event params are looking good for seller';
    is scalar @segment_args, 2, 'Two segments tracks fired';
    is $_->[2], 'p2p_order_timeout_refund', 'p2p order timeout refund sent' foreach @segment_args;

    BOM::Test::Helper::P2P::reset_escrow();
    $emit_mock->unmock_all;
    $p2p_mock->unmock_all;
    $track_mock->unmock_all;
    $mock_segment->unmock_all;
};

done_testing();
