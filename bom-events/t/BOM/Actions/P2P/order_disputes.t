use strict;
use warnings;
use utf8;

use Test::More;
use Test::Deep;
use Test::MockModule;
use BOM::Event::Actions::P2P;
use BOM::Test::Helper::P2P;
use Date::Utility;
use Time::Moment;
use BOM::Event::Process;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Config::Runtime;

use JSON::MaybeUTF8 qw(decode_json_utf8);

BOM::Test::Helper::P2P::bypass_sendbird();

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$config->dispute_response_time(6);

my @emissions;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->redefine(
    'emit' => sub {
        my ($event, $args) = @_;
        push @emissions,
            {
            type    => $event,
            details => $args
            };
    });

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
        push @segment_args, {@_[1 .. $#_]};
        return Future->done(1);
    });

BOM::Test::Helper::P2P::create_escrow();

subtest 'Order disputes' => sub {
    my @scenarios = ({
            disputer     => 'seller',
            reason       => 'buyer_not_paid',
            buyer_title  => 'We’re investigating and need more info',
            seller_title => 'We’re investigating your dispute',
        },
        {
            disputer     => 'seller',
            reason       => 'buyer_third_party_payment_method',
            buyer_title  => 'We need your account details',
            seller_title => 'We’re investigating your dispute',
        },
        {
            disputer     => 'buyer',
            reason       => 'seller_not_released',
            buyer_title  => 'We’re investigating your dispute',
            seller_title => 'We’re investigating and need more info',
        },
        {
            disputer     => 'buyer',
            reason       => 'buyer_overpaid',
            buyer_title  => 'We’re investigating your dispute',
            seller_title => 'We’re investigating and need more info',
        },
        {
            disputer     => 'seller',
            reason       => 'buyer_underpaid',
            buyer_title  => 'We’re investigating and need more info',
            seller_title => 'We’re investigating your dispute',
        },
        {
            disputer     => 'seller',
            reason       => 'buyer_overpaid',
            buyer_title  => 'You’ve paid more than the order amount',
            seller_title => 'Please return the excess funds',
        },
        {
            disputer     => 'buyer',
            reason       => 'buyer_underpaid',
            buyer_title  => 'Please make the full payment',
            seller_title => 'The buyer hasn’t made the full payment',
        },
    );

    for my $scenario (@scenarios) {
        for my $ad_type ('buy', 'sell') {
            my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
                amount => 100,
                type   => $ad_type
            );
            my ($client, $order) = BOM::Test::Helper::P2P::create_order(
                advert_id => $advert->{id},
                balance   => 100
            );
            BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});

            my %parties;
            @parties{('buyer', 'seller')} = $ad_type eq 'buy' ? ($advertiser, $client) : ($client, $advertiser);

            $parties{$scenario->{disputer}}->p2p_create_order_dispute(
                id             => $order->{id},
                dispute_reason => $scenario->{reason},
            );
            my $seller_nickname = $ad_type eq 'buy' ? $order->{client_details}->{name}     : $order->{advertiser_details}->{name};
            my $buyer_nickname  = $ad_type eq 'buy' ? $order->{advertiser_details}->{name} : $order->{client_details}->{name};

            @segment_args = ();
            @emissions    = ();
            BOM::Event::Actions::P2P::order_updated({
                    client_loginid => $parties{$scenario->{disputer}}->loginid,
                    order_id       => $order->{id},
                    order_event    => 'dispute',
                })->get;

            is scalar @emissions, 1, 'event emitted';
            BOM::Event::Process->new(category => 'track')->process($emissions[$#emissions])->get;
            my %common_args = (
                disputer              => $scenario->{disputer},
                dispute_reason        => $scenario->{reason},
                order_id              => $order->{id},
                dispute_response_time => 6,
                buyer_nickname        => $buyer_nickname  // '',
                seller_nickname       => $seller_nickname // '',
                lang                  => ignore(),
                brand                 => ignore(),
            );

            cmp_deeply(
                \@segment_args,
                bag({
                        event      => 'p2p_order_dispute',
                        properties => {
                            user_role => 'seller',
                            loginid   => $parties{seller}->loginid,
                            title     => $scenario->{seller_title},
                            %common_args,
                        },
                        context => ignore(),
                    },
                    {
                        event      => 'p2p_order_dispute',
                        properties => {
                            user_role => 'buyer',
                            loginid   => $parties{buyer}->loginid,
                            title     => $scenario->{buyer_title},
                            %common_args,
                        },
                        context => ignore(),
                    },
                ),
                "Expected events fired for $scenario->{reason} dispute by $scenario->{disputer} for $ad_type ad",
            ) or note explain \@segment_args;
        }
    }
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
                @emissions        = ();
                BOM::Event::Actions::P2P::order_updated({
                        client_loginid => $client->loginid,
                        order_id       => $order->{id},
                        order_event    => $event,
                    })->get;

                # Get fresh order data
                $order = $advertiser->p2p_order_info(id => $order->{id});

                is scalar @emissions, 1, 'event emitted';
                BOM::Event::Process->new(category => 'track')->process($emissions[$#emissions])->get;

                # Check whether the track_events are called
                is scalar @track_event_args, 2,                  'Two track_event fired';
                is scalar @segment_args,     2,                  'Two segments tracks fired';
                is $_->{event},              "p2p_order_$event", "P2P $event sent" foreach @segment_args;

                my $user_role       = $type eq 'buy' ? 'buyer'                              : 'seller';
                my $order_type      = $type eq 'buy' ? 'sell'                               : 'buy';
                my $disputer        = $type eq 'buy' ? 'seller'                             : 'buyer';
                my $buyer_user_id   = $type eq 'buy' ? $advertiser->binary_user_id          : $client->binary_user_id;
                my $seller_user_id  = $type eq 'buy' ? $client->binary_user_id              : $advertiser->binary_user_id;
                my $seller_nickname = $type eq 'buy' ? $order->{client_details}->{name}     : $order->{advertiser_details}->{name};
                my $buyer_nickname  = $type eq 'buy' ? $order->{advertiser_details}->{name} : $order->{client_details}->{name};

                my $buyer_properties = {
                    event      => "p2p_order_$event",
                    client     => isa('BOM::User::Client'),
                    properties => {
                        user_role        => $user_role,
                        order_type       => $order_type,
                        order_id         => $order->{id},
                        buyer_user_id    => $buyer_user_id,
                        seller_user_id   => $seller_user_id,
                        currency         => $order->{account_currency},
                        exchange_rate    => $order->{rate_display},
                        local_currency   => $order->{local_currency},
                        buyer_nickname   => $buyer_nickname  // '',
                        seller_nickname  => $seller_nickname // '',
                        amount           => $order->{amount},
                        dispute_reason   => $order->{dispute_details}->{dispute_reason},
                        disputer         => $disputer,
                        order_created_at => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
                        order_expire_at  => Time::Moment->from_epoch(Date::Utility->new($order->{expiry_time})->epoch)->to_string,
                    }};

                my $seller_properties = {
                    event      => "p2p_order_$event",
                    client     => isa('BOM::User::Client'),
                    properties => {
                        user_role        => $user_role eq 'buyer' ? 'seller' : 'buyer',
                        order_type       => $order_type,
                        order_id         => $order->{id},
                        buyer_user_id    => $buyer_user_id,
                        seller_user_id   => $seller_user_id,
                        currency         => $order->{account_currency},
                        exchange_rate    => $order->{rate_display},
                        local_currency   => $order->{local_currency},
                        buyer_nickname   => $buyer_nickname  // '',
                        seller_nickname  => $seller_nickname // '',
                        amount           => $order->{amount},
                        dispute_reason   => $order->{dispute_details}->{dispute_reason},
                        disputer         => $disputer,
                        order_created_at => Time::Moment->from_epoch(Date::Utility->new($order->{created_time})->epoch)->to_string,
                        order_expire_at  => Time::Moment->from_epoch(Date::Utility->new($order->{expiry_time})->epoch)->to_string,
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
