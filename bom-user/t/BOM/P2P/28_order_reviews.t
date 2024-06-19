use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Exception;
use Test::Deep;
use Test::MockModule;
use Test::MockTime  qw(set_fixed_time restore_time);
use JSON::MaybeUTF8 qw(:v1);

use BOM::User::Client;
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::P2PWithClient;
use BOM::Test::Helper::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;
use Date::Utility;

my $rule_engine = BOM::Rules::Engine->new();

BOM::Test::Helper::P2PWithClient::bypass_sendbird();
BOM::Test::Helper::P2PWithClient::create_payment_methods();
BOM::Test::Helper::P2PWithClient::create_escrow();

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$config->review_period(2);
$config->transaction_verification_countries([]);
$config->transaction_verification_countries_all(0);

my $emitted_events;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(emit => sub { push $emitted_events->{$_[0]}->@*, $_[1] });

my $redis      = BOM::Config::Redis->redis_p2p;
my $review_key = 'P2P::ORDER::REVIEWABLE_START_AT';
my $other_guy  = BOM::Test::Helper::P2PWithClient::create_advertiser();

subtest 'validaton' => sub {
    my ($advertiser, $ad)    = BOM::Test::Helper::P2P::create_advert();
    my ($client,     $order) = BOM::Test::Helper::P2PWithClient::create_order(advert_id => $ad->{id});

    cmp_deeply(
        exception {
            $other_guy->p2p_order_review(
                order_id => $order->{id},
                rating   => 5
            )
        },
        {
            error_code => 'OrderNotFound',
        },
        'order not belonging to client'
    );

    cmp_deeply(
        exception {
            $client->p2p_order_review(
                order_id => $order->{id} + 1,
                rating   => 5
            )
        },
        {
            error_code => 'OrderNotFound',
        },
        'wrong order id'
    );

    my $info;
    for my $status ('pending', 'buyer-confirmed', 'timed-out') {
        BOM::Test::Helper::P2PWithClient::set_order_status($client, $order->{id}, $status);
        is $client->p2p_order_info(id => $order->{id})->{is_reviewable},     0, "client cannot review $status order";
        is $advertiser->p2p_order_info(id => $order->{id})->{is_reviewable}, 0, "advertiser review $status order";

        cmp_deeply(
            exception {
                $client->p2p_order_review(
                    order_id => $order->{id},
                    rating   => 5
                )
            },
            {
                error_code => 'OrderReviewNotComplete',
            },
            "correct error when attempting review in $status status"
        );
    }

    for my $status ('refunded', 'completed', 'disputed', 'dispute-completed', 'dispute-refunded') {
        BOM::Test::Helper::P2PWithClient::set_order_status($client, $order->{id}, $status);
        is $client->p2p_order_info(id => $order->{id})->{is_reviewable},     0, "client cannot review $status order";
        is $advertiser->p2p_order_info(id => $order->{id})->{is_reviewable}, 0, "advertiser review $status order";

        cmp_deeply(
            exception {
                $client->p2p_order_review(
                    order_id => $order->{id},
                    rating   => 5
                )
            },
            {
                error_code => 'OrderReviewStatusInvalid',
            },
            "correct error when attempting review in $status status"
        );
    }

    BOM::Test::Helper::P2PWithClient::set_order_status($client, $order->{id}, 'pending');
    $client->p2p_order_confirm(id => $order->{id});
    $advertiser->p2p_order_confirm(id => $order->{id});

    is $client->p2p_order_info(id => $order->{id})->{is_reviewable},     1, 'client can review completed order';
    is $advertiser->p2p_order_info(id => $order->{id})->{is_reviewable}, 1, 'advertiser can review completed order';

    my $completion = $client->p2p_order_info(id => $order->{id})->{completion_time};
    like $completion, qr/^\d+$/, 'Order has completion';

    my $redis_score = $redis->zscore($review_key, $order->{id} . '|' . $advertiser->loginid);
    ok abs($completion - ($redis_score // 0)) <= 1, 'redis completion ts exists for advertiser and within 1 second';
    $redis_score = $redis->zscore($review_key, $order->{id} . '|' . $client->loginid);
    ok abs($completion - ($redis_score // 0)) <= 1, 'redis completion ts exists for client and within 1 second';

    set_fixed_time($completion + ((60 * 60) * 2) + 1);    # 2 hours 1 sec
    is $client->p2p_order_info(id => $order->{id})->{is_reviewable},     0, 'client cannot review beyond period';
    is $advertiser->p2p_order_info(id => $order->{id})->{is_reviewable}, 0, 'advertiser cannot review beyond period';

    cmp_deeply(
        exception {
            $client->p2p_order_review(
                order_id => $order->{id},
                rating   => 5
            )
        },
        {
            error_code     => 'OrderReviewPeriodExpired',
            message_params => [2],
        },
        'error for create review beyond allowed period'
    );

    set_fixed_time($completion + ((60 * 60) * 2));
    is $client->p2p_order_info(id => $order->{id})->{is_reviewable},     1, 'client can review at end of period';
    is $advertiser->p2p_order_info(id => $order->{id})->{is_reviewable}, 1, 'advertiser can review at end of period';

    is(
        exception {
            $client->p2p_order_review(
                order_id => $order->{id},
                rating   => 5
            )
        },
        undef,
        'client can create review at end of period'
    );

    is $client->p2p_order_info(id => $order->{id})->{is_reviewable},       0,     'client cannot review again';
    is $advertiser->p2p_order_info(id => $order->{id})->{is_reviewable},   1,     'advertiser can review after client reviewed';
    is $redis->zscore($review_key, $order->{id} . '|' . $client->loginid), undef, 'order removed from redis key for client';
    ok $redis->zscore($review_key, $order->{id} . '|' . $advertiser->loginid), 'order not removed from redis key for advertiser';

    is(
        exception {
            $advertiser->p2p_order_review(
                order_id => $order->{id},
                rating   => 5
            )
        },
        undef,
        'advertiser can create review at end of period'
    );

    is $client->p2p_order_info(id => $order->{id})->{is_reviewable},           0,     'client cannot review again';
    is $advertiser->p2p_order_info(id => $order->{id})->{is_reviewable},       0,     'advertiser cannot review again';
    is $redis->zscore($review_key, $order->{id} . '|' . $advertiser->loginid), undef, 'order removed from redis key for advertiser';
    is $redis->zscore($review_key, $order->{id} . '|' . $client->loginid),     undef, 'order removed from redis key for client';

    restore_time();
};

subtest 'create reviews' => sub {
    my ($advertiser, $ad)    = BOM::Test::Helper::P2P::create_advert();
    my ($client,     $order) = BOM::Test::Helper::P2P::create_order(advert_id => $ad->{id});
    $client->p2p_order_confirm(id => $order->{id});
    $advertiser->p2p_order_confirm(id => $order->{id});

    my $rating = {
        rating_average      => undef,
        rating_count        => 0,
        recommended_average =>,
        undef,
        recommended_count => undef,
    };

    my $info = $other_guy->p2p_advertiser_info(id => $client->_p2p_advertiser_cached->{id});
    cmp_deeply($info, superhashof($rating), 'unreviewed client advertiser info');

    $info = $other_guy->p2p_advertiser_info(id => $advertiser->_p2p_advertiser_cached->{id});
    cmp_deeply($info, superhashof($rating), 'unreviewed advertiser advertiser info');

    undef $emitted_events;

    cmp_deeply(
        $client->p2p_order_review(
            order_id    => $order->{id},
            rating      => 5,
            recommended => 1
        ),
        {
            advertiser_id => $advertiser->_p2p_advertiser_cached->{id},
            created_time  => re('\d+'),
            order_id      => $order->{id},
            rating        => 5,
            recommended   => 1,
        },
        'client reviews advertiser'
    );

    cmp_deeply(
        $emitted_events,
        {
            p2p_advertiser_updated => [{
                    client_loginid => $advertiser->loginid,
                }
            ],
            p2p_adverts_updated => [{
                    advertiser_id => $advertiser->_p2p_advertiser_cached->{id},
                }
            ],
            p2p_order_updated => [{
                    client_loginid => $client->loginid,
                    order_event    => 'review_created',
                    order_id       => $order->{id},
                    self_only      => 1,
                }]
        },
        'events emitted for advertiser review',
    );

    $rating = {
        rating_average      => '5.00',
        rating_count        => 1,
        recommended_average =>,
        '100.0',
        recommended_count => 1,
        is_recommended    => 1,
    };
    $info = $client->p2p_advertiser_info(id => $advertiser->_p2p_advertiser_cached->{id});
    cmp_deeply($info, superhashof($rating), 'rating info in advertiser info for client');

    $info = $client->p2p_order_info(id => $order->{id});
    cmp_deeply(
        $info->{review_details},
        {
            created_time => re('\d+'),
            rating       => 5,
            recommended  => 1
        },
        'review_details in order info for client'
    );

    is $info->{advertiser_details}{is_recommended}, 1, 'order info advertiser_details/is_recommended exists for client';
    ok !exists $info->{client_details}{is_recommended}, 'order info client_details/is_recommended not present for client';

    $info = $advertiser->p2p_order_info(id => $order->{id});
    is $info->{client_details}{is_recommended}, undef, 'order info client_details/is_recommended exists for advertiser';
    ok !exists $info->{advertiser_details}{is_recommended}, 'order info advertiser_details/is_recommended not present for advertiser';

    $info = $client->p2p_advert_info(id => $ad->{id})->{advertiser_details};
    cmp_deeply($info, superhashof($rating), 'advertiser rating info in advert info for client',);

    $rating->{is_recommended} = undef;
    $info = $other_guy->p2p_advert_info(id => $ad->{id})->{advertiser_details};
    cmp_deeply($info, superhashof($rating), 'reviewed advertiser advertiser info in advert info for other guy');

    delete $rating->{is_recommended};
    $info = $advertiser->p2p_advert_info(id => $ad->{id})->{advertiser_details};
    cmp_deeply($info, superhashof($rating), 'advertiser rating info in advert info for advertiser self');

    $info = $advertiser->p2p_advertiser_update(payment_info => 'xxx');
    cmp_deeply($info, superhashof($rating), 'reviewed advertiser gets rating in advertiser update');

    cmp_deeply(
        exception {
            $client->p2p_order_review(
                order_id => $order->{id},
                rating   => 5
            )
        },
        {
            error_code => 'OrderReviewExists',
        },
        'client cannot review again'
    );

    undef $emitted_events;

    cmp_deeply(
        $advertiser->p2p_order_review(
            order_id => $order->{id},
            rating   => 4
        ),
        {
            advertiser_id => $client->_p2p_advertiser_cached->{id},
            created_time  => re('\d+'),
            order_id      => $order->{id},
            rating        => 4,
            recommended   => undef
        },
        'advertiser reviews client'
    );

    cmp_deeply(
        $emitted_events,
        {
            p2p_advertiser_updated => [{
                    client_loginid => $client->loginid,
                }
            ],
            p2p_adverts_updated => [{
                    advertiser_id => $client->_p2p_advertiser_cached->{id},
                }
            ],
            p2p_order_updated => [{
                    client_loginid => $advertiser->loginid,
                    order_event    => 'review_created',
                    order_id       => $order->{id},
                    self_only      => 1,
                }]
        },
        'events emitted for advertiser review',
    );

    $rating = {
        rating_average      => '4.00',
        rating_count        => 1,
        recommended_average =>,
        undef,
        recommended_count => undef,
        is_recommended    => undef,
    };

    cmp_deeply(
        $advertiser->p2p_order_info(id => $order->{id})->{review_details},
        {
            created_time => re('\d+'),
            rating       => 4,
            recommended  => undef
        },
        'review_details in order info for advertiser'
    );

    $info = $advertiser->p2p_advertiser_info(id => $client->_p2p_advertiser_cached->{id});
    cmp_deeply($info, superhashof($rating), 'advertiser sees clients rating in advertiser info');

    delete $client->{_p2p_advertiser_cached};
    $info = $client->p2p_advertiser_info;
    delete $rating->{is_recommended};
    cmp_deeply($info, superhashof($rating), 'rating info in advertiser info for client');

    cmp_deeply(
        exception {
            $advertiser->p2p_order_review(
                order_id => $order->{id},
                rating   => 5
            )
        },
        {
            error_code => 'OrderReviewExists',
        },
        'advertiser cannot review again'
    );
};

subtest 'buy advert' => sub {
    my ($advertiser, $ad)    = BOM::Test::Helper::P2P::create_advert(type => 'buy');
    my ($client,     $order) = BOM::Test::Helper::P2PWithClient::create_order(
        advert_id => $ad->{id},
        amount    => 10
    );
    $advertiser->p2p_order_confirm(id => $order->{id});
    $client->p2p_order_confirm(id => $order->{id});
    my $completion = $client->p2p_order_info(id => $order->{id})->{completion_time};

    my $redis_score = $redis->zscore($review_key, $order->{id} . '|' . $advertiser->loginid);
    ok abs($completion - ($redis_score // 0)) <= 1, 'redis completion ts exists for advertiser and within 1 second';
    $redis_score = $redis->zscore($review_key, $order->{id} . '|' . $client->loginid);
    ok abs($completion - ($redis_score // 0)) <= 1, 'redis completion ts exists for client and within 1 second';

    $advertiser->p2p_order_review(
        order_id => $order->{id},
        rating   => 5
        ),

        is $redis->zscore($review_key, $order->{id} . '|' . $advertiser->loginid), undef, 'order removed from redis key for advertiser';
    ok $redis->zscore($review_key, $order->{id} . '|' . $client->loginid), 'order not removed from redis key for client';

    $client->p2p_order_review(
        order_id => $order->{id},
        rating   => 5
        ),

        is $redis->zscore($review_key, $order->{id} . '|' . $advertiser->loginid), undef, 'order removed from redis key for advertiser';
    is $redis->zscore($review_key, $order->{id} . '|' . $client->loginid), undef, 'order removed from redis key for client';
};

subtest 'duplicate review from DB' => sub {
    my ($advertiser, $ad)    = BOM::Test::Helper::P2P::create_advert();
    my ($client,     $order) = BOM::Test::Helper::P2PWithClient::create_order(advert_id => $ad->{id});

    $client->p2p_order_confirm(id => $order->{id});
    $advertiser->p2p_order_confirm(id => $order->{id});

    cmp_deeply(
        $client->p2p_order_review(
            order_id    => $order->{id},
            rating      => 5,
            recommended => 1
        ),
        {
            advertiser_id => $advertiser->_p2p_advertiser_cached->{id},
            created_time  => re('\d+'),
            order_id      => $order->{id},
            rating        => 5,
            recommended   => 1
        },
        'client reviews advertiser'
    );

    my $merging_module = Test::MockModule->new('BOM::User::Client');
    my $order_data     = $client->_p2p_orders(id => $order->{id})->[0];
    $merging_module->mock(
        '_p2p_orders',
        sub {
            return [{%$order_data, advertiser_review_rating => undef}];
        });

    cmp_deeply(
        exception {
            $client->p2p_order_review(
                order_id    => $order->{id},
                rating      => 5,
                recommended => 1
            )
        },
        {
            error_code => 'OrderReviewExists',
        },
        'client cannot review again, error is coming from db'
    );
};

done_testing();
