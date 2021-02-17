use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;
use feature 'state';
use BOM::Event::Actions::P2P;

use BOM::Test;
use BOM::Config::Runtime;
use Data::Dumper;
use BOM::Database::ClientDB;
use BOM::Config::Redis;
use BOM::Test::Helper::P2P;
use BOM::Event::Process;
use Date::Utility;
use Time::Moment;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Platform::Context qw(localize request);

use JSON::MaybeUTF8 qw(decode_json_utf8);

BOM::Test::Helper::P2P::bypass_sendbird();

my $mock = Test::MockModule->new('BOM::Event::Services::Track');
my @track_event_args;

my $mock_segment = Test::MockModule->new('WebService::Async::Segment::Customer');
my @segment_args;

$mock->mock(
    'track_event',
    sub {
        # Note the event must fire two `track_events`, one for each party
        push @track_event_args, {@_};
        return $mock->original('track_event')->(@_);
    });

$mock_segment->mock(
    'track',
    sub {
        push @segment_args, [@_];
        return $mock_segment->original('track')->(@_);
    });

BOM::Test::Helper::P2P::create_escrow();

subtest 'Order dispute type buy' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount => 100,
        type   => 'sell'
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => 100
    );

    BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
    $client->p2p_create_order_dispute(
        id             => $order->{id},
        dispute_reason => 'seller_not_released',
    );

    @track_event_args = ();
    BOM::Event::Actions::P2P::order_updated({
        client_loginid => $client->loginid,
        order_id       => $order->{id},
        order_event    => 'dispute',
    });

    # Get fresh order data
    $order = $client->p2p_order_info(id => $order->{id});

    # Check whether the track_events are called
    is scalar @track_event_args, 2, 'Two track_event fired';
    is scalar @segment_args,     2, 'Two segments tracks fired';
    is $_->[2], 'p2p_order_dispute', 'p2p order dispute sent' foreach @segment_args;

    my @expected_track_event_args = ({
            event      => 'p2p_order_dispute',
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
                dispute_reason   => $order->{dispute_details}->{dispute_reason},
                disputer         => 'buyer',
                order_created_at => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
            }
        },
        {
            event      => 'p2p_order_dispute',
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
                dispute_reason   => $order->{dispute_details}->{dispute_reason},
                disputer         => 'buyer',
                order_created_at => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
            }});

    cmp_deeply $track_event_args[0], superhashof($expected_track_event_args[0]), 'Track event params are looking good for buyer';
    cmp_deeply $track_event_args[1], superhashof($expected_track_event_args[1]), 'Track event params are looking good for seller';
};

subtest 'Order dispute type sell' => sub {
    my $amount = 100;
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount => $amount,
        type   => 'buy'
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        balance   => $amount
    );

    BOM::Test::Helper::P2P::set_order_disputable($advertiser, $order->{id});
    my $response = $client->p2p_create_order_dispute(
        id             => $order->{id},
        dispute_reason => 'buyer_not_paid',
    );

    @track_event_args = ();
    @segment_args     = ();
    BOM::Event::Actions::P2P::order_updated({
        client_loginid => $client->loginid,
        order_id       => $order->{id},
        order_event    => 'dispute',
    });

    # Get fresh order data
    $order = $advertiser->p2p_order_info(id => $order->{id});

    # Check whether the track_events are called
    is scalar @track_event_args, 2, 'Two track_event fired';
    is scalar @segment_args,     2, 'Two segments tracks fired';
    is $_->[2], 'p2p_order_dispute', 'p2p order dispute sent' foreach @segment_args;

    my @expected_track_event_args = ({
            event      => 'p2p_order_dispute',
            loginid    => $advertiser->loginid,
            properties => {
                user_role        => 'buyer',
                order_type       => 'sell',
                seller_nickname  => '',
                order_id         => $order->{id},
                buyer_user_id    => $advertiser->binary_user_id,
                seller_user_id   => $client->binary_user_id,
                currency         => $order->{account_currency},
                loginid          => $advertiser->loginid,
                exchange_rate    => $order->{rate_display},
                local_currency   => $order->{local_currency},
                buyer_nickname   => $order->{advertiser_details}->{name} // '',
                seller_nickname  => $order->{client_details}->{name}     // '',
                amount           => $order->{amount},
                dispute_reason   => $order->{dispute_details}->{dispute_reason},
                disputer         => 'seller',
                order_created_at => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
            }
        },
        {
            event      => 'p2p_order_dispute',
            loginid    => $client->loginid,
            properties => {
                user_role        => 'seller',
                order_type       => 'sell',
                order_id         => $order->{id},
                buyer_user_id    => $advertiser->binary_user_id,
                seller_user_id   => $client->binary_user_id,
                currency         => $order->{account_currency},
                loginid          => $client->loginid,
                exchange_rate    => $order->{rate_display},
                local_currency   => $order->{local_currency},
                buyer_nickname   => $order->{advertiser_details}->{name} // '',
                seller_nickname  => $order->{client_details}->{name}     // '',
                amount           => $order->{amount},
                dispute_reason   => $order->{dispute_details}->{dispute_reason},
                disputer         => 'seller',
                order_created_at => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
            }});

    cmp_deeply $track_event_args[0], superhashof($expected_track_event_args[0]), 'Track event params are looking good for buyer';
    cmp_deeply $track_event_args[1], superhashof($expected_track_event_args[1]), 'Track event params are looking good for seller';
};

subtest 'Dispute resolution' => sub {
    my @events = qw(dispute_complete dispute_refund dispute_fraud_complete dispute_fraud_refund);
    my @types  = qw(buy sell);

    for my $event (@events) {
        for my $type (@types) {
            subtest "P2P $event ad type $type" => sub {
                my $amount = 100;
                my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
                    amount => $amount,
                    type   => $type,
                );

                my ($client, $order) = BOM::Test::Helper::P2P::create_order(
                    advert_id => $advert->{id},
                    balance   => $amount
                );

                BOM::Test::Helper::P2P::set_order_disputable($advertiser, $order->{id});
                my $response = $client->p2p_create_order_dispute(
                    id             => $order->{id},
                    dispute_reason => 'buyer_overpaid',
                );

                # Then somebody from BO triggers this
                @track_event_args = ();
                @segment_args     = ();
                BOM::Event::Actions::P2P::order_updated({
                    client_loginid => $client->loginid,
                    order_id       => $order->{id},
                    order_event    => $event,
                });

                # Get fresh order data
                $order = $advertiser->p2p_order_info(id => $order->{id});

                # Check whether the track_events are called
                is scalar @track_event_args, 2, 'Two track_event fired';
                is scalar @segment_args,     2, 'Two segments tracks fired';
                is $_->[2], "p2p_order_$event", "P2P $event sent" foreach @segment_args;

                my $user_role       = $type eq 'buy' ? 'buyer'                              : 'seller';
                my $order_type      = $type eq 'buy' ? 'sell'                               : 'buy';
                my $disputer        = $type eq 'buy' ? 'seller'                             : 'buyer';
                my $buyer_user_id   = $type eq 'buy' ? $advertiser->binary_user_id          : $client->binary_user_id;
                my $seller_user_id  = $type eq 'buy' ? $client->binary_user_id              : $advertiser->binary_user_id;
                my $seller_nickname = $type eq 'buy' ? $order->{client_details}->{name}     : $order->{advertiser_details}->{name};
                my $buyer_nickname  = $type eq 'buy' ? $order->{advertiser_details}->{name} : $order->{client_details}->{name};

                my $buyer_properties = {
                    event      => "p2p_order_$event",
                    loginid    => $advertiser->loginid,
                    properties => {
                        user_role        => $user_role,
                        order_type       => $order_type,
                        seller_nickname  => '',
                        order_id         => $order->{id},
                        buyer_user_id    => $buyer_user_id,
                        seller_user_id   => $seller_user_id,
                        currency         => $order->{account_currency},
                        loginid          => $advertiser->loginid,
                        exchange_rate    => $order->{rate_display},
                        local_currency   => $order->{local_currency},
                        buyer_nickname   => $buyer_nickname  // '',
                        seller_nickname  => $seller_nickname // '',
                        amount           => $order->{amount},
                        dispute_reason   => $order->{dispute_details}->{dispute_reason},
                        disputer         => $disputer,
                        order_created_at => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
                    }};

                my $seller_properties = {
                    event      => "p2p_order_$event",
                    loginid    => $client->loginid,
                    properties => {
                        user_role        => $user_role eq 'buyer' ? 'seller' : 'buyer',
                        order_type       => $order_type,
                        order_id         => $order->{id},
                        buyer_user_id    => $buyer_user_id,
                        seller_user_id   => $seller_user_id,
                        currency         => $order->{account_currency},
                        loginid          => $client->loginid,
                        exchange_rate    => $order->{rate_display},
                        local_currency   => $order->{local_currency},
                        buyer_nickname   => $buyer_nickname  // '',
                        seller_nickname  => $seller_nickname // '',
                        amount           => $order->{amount},
                        dispute_reason   => $order->{dispute_details}->{dispute_reason},
                        disputer         => $disputer,
                        order_created_at => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
                    }};

                if ($type ne 'buy') {
                    # The hunter becomes the prey
                    my $swap = $seller_properties;
                    $seller_properties = $buyer_properties;
                    $buyer_properties  = $swap;
                }

                my @expected_track_event_args = ($buyer_properties, $seller_properties);
                cmp_deeply $track_event_args[0], superhashof($expected_track_event_args[0]),
                    'Track event params are looking good for ' . $buyer_properties->{properties}->{user_role};
                cmp_deeply $track_event_args[1], superhashof($expected_track_event_args[1]),
                    'Track event params are looking good for ' . $seller_properties->{properties}->{user_role};

            };
        }
    }
};

$mock->unmock_all;
$mock_segment->unmock_all;
BOM::Test::Helper::P2P::reset_escrow();

done_testing()
