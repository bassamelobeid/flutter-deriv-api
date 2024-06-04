use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::P2PWithClient;
use BOM::Test::Helper::Client;
use BOM::Rules::Engine;
use BOM::Config::Runtime;

my $rule_engine = BOM::Rules::Engine->new();

BOM::Test::Helper::P2PWithClient::bypass_sendbird();
BOM::Test::Helper::P2PWithClient::create_escrow();

my $emitted_events;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(emit => sub { push $emitted_events->{$_[0]}->@*, $_[1] });

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$config->transaction_verification_countries([]);
$config->transaction_verification_countries_all(0);

subtest 'favourites' => sub {
    my $client = BOM::Test::Helper::Client::create_client();
    my ($me,    $my_ad)    = BOM::Test::Helper::P2P::create_advert();
    my ($fav,   $fav_ad)   = BOM::Test::Helper::P2P::create_advert();
    my ($other, $other_ad) = BOM::Test::Helper::P2P::create_advert();

    cmp_deeply(exception { $client->p2p_advertiser_relations }, {error_code => 'AdvertiserNotRegistered'}, 'not an advertiser');

    my $info = $client->p2p_advertiser_info(id => $me->_p2p_advertiser_cached->{id});
    is $info->{is_blocked},   0, 'is_blocked = 0 for non advertiser viewing advertiser';
    is $info->{is_favourite}, 0, 'is_favourite = 0 for non advertiser viewing advertiser';

    cmp_deeply(
        $me->p2p_advertiser_relations,
        {
            favourite_advertisers => [],
            blocked_advertisers   => [],
        },
        'relations of new advertiser'
    );

    undef $emitted_events;
    cmp_deeply(
        $me->p2p_advertiser_relations(add_favourites => [$fav->_p2p_advertiser_cached->{id}]),
        {
            favourite_advertisers => [{
                    created_time => re('\d+'),
                    name         => $fav->_p2p_advertiser_cached->{name},
                    id           => $fav->_p2p_advertiser_cached->{id},
                }
            ],
            blocked_advertisers => [],
        },
        'add favourite'
    );

    cmp_deeply(
        $emitted_events,
        {
            p2p_advertiser_updated => [{client_loginid => $fav->loginid}],
            p2p_adverts_updated    => [{advertiser_id  => $fav->_p2p_advertiser_cached->{id}}]
        },
        'events fired'
    );

    $info = $me->p2p_advertiser_info(id => $fav->_p2p_advertiser_cached->{id});
    is $info->{is_favourite}, 1, 'is_favourite in advertiser info viewing a favourite';
    is $info->{is_blocked},   0, 'is_favourite in advertiser info viewing a favourite';

    my @ads = $me->p2p_advert_list(type => 'sell')->@*;
    cmp_deeply([map { $_->{id} } @ads], bag($my_ad->{id}, $fav_ad->{id}, $other_ad->{id}), 'see all ads by default');

    for my $ad (@ads) {
        if ($ad->{id} == $my_ad->{id}) {
            ok !(
                   exists $ad->{advertiser_details}{is_blocked}
                or exists $ad->{advertiser_details}{is_favourite}
                ),
                'blocked and favourite flags not present in own ad';
        } else {
            is($ad->{advertiser_details}{is_favourite}, ($ad->{id} == $fav_ad->{id} ? 1 : 0), 'ad favourite flag');
            is $ad->{advertiser_details}{is_blocked}, 0, 'ad is not blocked';
        }
    }

    @ads = $me->p2p_advertiser_adverts->@*;
    ok(!exists $_->{advertiser_details}{is_favourite}, 'is_favourite not present in my ads') for @ads;
    ok(!exists $_->{advertiser_details}{is_blocked},   'is_blocked not present in my ads')   for @ads;

    cmp_deeply([
            map { $_->{id} } $me->p2p_advert_list(
                type            => 'sell',
                favourites_only => 1
            )->@*
        ],
        [$fav_ad->{id}],
        'ad list favourites only'
    );

    ok $me->p2p_advert_info(id => $fav_ad->{id})->{advertiser_details}{is_favourite}, 'favourite flag in advert info';

    cmp_deeply([
            map { $_->{id} } $fav->p2p_advert_list(
                type            => 'sell',
                favourites_only => 1
            )->@*
        ],
        [],
        'favourite sees no favourites'
    );

    cmp_deeply([
            map { $_->{id} } $other->p2p_advert_list(
                type            => 'sell',
                favourites_only => 1
            )->@*
        ],
        [],
        'third advertiser sees no favourites'
    );

    ok !exists $fav->p2p_advert_info(id => $fav_ad->{id})->{advertiser_details}{is_favourite},
        'favourite flag not in advert info for favourite themself';

    undef $emitted_events;
    my $update = $me->p2p_advertiser_relations(
        add_favourites => [$other->_p2p_advertiser_cached->{id}],
        add_blocked    => [$fav->_p2p_advertiser_cached->{id}]);
    is $update->{favourite_advertisers}[0]{id}, $other->_p2p_advertiser_cached->{id}, 'new favourite';
    is $update->{blocked_advertisers}[0]{id},   $fav->_p2p_advertiser_cached->{id},   'blocked old favourite';

    $info = $me->p2p_advertiser_info(id => $fav->_p2p_advertiser_cached->{id});
    ok !exists $info->{favourite}, 'favourite flag in advertiser info not present';

    cmp_deeply(
        $emitted_events,
        {
            p2p_advertiser_updated => bag({client_loginid => $fav->loginid}, {client_loginid => $other->loginid}),
            p2p_adverts_updated => bag({advertiser_id => $fav->_p2p_advertiser_cached->{id}}, {advertiser_id => $other->_p2p_advertiser_cached->{id}})
        },
        'events fired'
    );

    undef $emitted_events;
    cmp_deeply(
        $me->p2p_advertiser_relations(
            remove_favourites => [$other->_p2p_advertiser_cached->{id}],
            remove_blocked    => [$fav->_p2p_advertiser_cached->{id}]
        ),
        {
            favourite_advertisers => [],
            blocked_advertisers   => [],
        },
        'remove all relations'
    );

    cmp_deeply(
        $emitted_events,
        {
            p2p_advertiser_updated => bag({client_loginid => $fav->loginid}, {client_loginid => $other->loginid}),
            p2p_adverts_updated => bag({advertiser_id => $fav->_p2p_advertiser_cached->{id}}, {advertiser_id => $other->_p2p_advertiser_cached->{id}})
        },
        'events fired'
    );

    cmp_deeply(
        exception {
            $me->p2p_advertiser_relations(add_favourites => [$me->_p2p_advertiser_cached->{id}])
        },
        {error_code => 'AdvertiserRelationSelf'},
        'Cannot make self favourite'
    );

    cmp_deeply(
        exception {
            $me->p2p_advertiser_relations(remove_favourites => [$me->_p2p_advertiser_cached->{id}])
        },
        {error_code => 'AdvertiserRelationSelf'},
        'Cannot unfavourite self'
    );

    cmp_deeply(
        exception {
            $me->p2p_advertiser_relations(add_favourites => [-1])
        },
        {error_code => 'InvalidAdvertiserID'},
        'Cannot favourite invalid advertiser id'
    );

    cmp_deeply(
        exception {
            $me->p2p_advertiser_relations(remove_favourites => [-1])
        },
        {error_code => 'InvalidAdvertiserID'},
        'Cannot unfavourite invalid advertiser id'
    );

    # clean up for following tests
    $me->p2p_advert_update(
        id     => $my_ad->{id},
        delete => 1
    );
    $fav->p2p_advert_update(
        id     => $fav_ad->{id},
        delete => 1
    );
    $other->p2p_advert_update(
        id     => $other_ad->{id},
        delete => 1
    );
};

subtest 'blocking' => sub {
    my ($me,     $my_ad)     = BOM::Test::Helper::P2P::create_advert();
    my ($other1, $other1_ad) = BOM::Test::Helper::P2P::create_advert();
    my ($other2, $other2_ad) = BOM::Test::Helper::P2P::create_advert();

    my $advertiser_id = $me->p2p_advertiser_update(is_approved => 0)->{id};
    delete $me->{_p2p_advertiser_cached};

    cmp_deeply(
        exception {
            $me->p2p_advertiser_relations(add_blocked => [$other1->_p2p_advertiser_cached->{id}]),
        },
        {error_code => 'AdvertiserNotApprovedForBlock'},
        'Cannot block when not approved'
    );

    my ($block_date) = $me->db->dbic->dbh->selectrow_array(
        "UPDATE p2p.p2p_advertiser SET blocked_until=NOW() + INTERVAL '1 hour', is_approved = TRUE, is_listed = TRUE WHERE id = $advertiser_id RETURNING blocked_until"
    );
    delete $me->{_p2p_advertiser_cached};

    cmp_deeply(
        exception {
            $me->p2p_advertiser_relations(add_blocked => [$other1->_p2p_advertiser_cached->{id}]),
        },
        {
            error_code     => 'TemporaryBar',
            message_params => [$block_date]
        },
        'Cannot block when temp banned'
    );

    is(
        exception {
            $me->p2p_advertiser_relations(
                p2p_advertiser_relations => 1,
                add_blocked              => [],
                remove_blocked           => []
            ),
        },
        undef,
        'Can see relations when temp banned'
    );

    $me->db->dbic->dbh->do("UPDATE p2p.p2p_advertiser SET blocked_until=NULL WHERE id = $advertiser_id");
    delete $me->{_p2p_advertiser_cached};

    undef $emitted_events;
    cmp_deeply(
        $me->p2p_advertiser_relations(add_blocked => [$other1->_p2p_advertiser_cached->{id}]),
        {
            favourite_advertisers => [],
            blocked_advertisers   => [{
                    created_time => re('\d+'),
                    name         => $other1->_p2p_advertiser_cached->{name},
                    id           => $other1->_p2p_advertiser_cached->{id},
                }]
        },
        'advertiser update returns blocked advertiser details'
    );

    cmp_deeply(
        $emitted_events,
        {
            p2p_advertiser_updated => [{client_loginid => $other1->loginid}],
            p2p_adverts_updated    => [{advertiser_id  => $other1->_p2p_advertiser_cached->{id}}]
        },
        'events fired'
    );

    is $me->p2p_advert_info(id => $other1_ad->{id})->{is_visible}, 0, "blocker gets full response for blocked advertiser's ad but is_visible:0";

    cmp_deeply(
        [map { $_->{id} } $me->p2p_advert_list(type => 'sell')->@*],
        bag($my_ad->{id}, $other2_ad->{id}),
        "blocker doesn't see blocked advertisers ad at all (filtered out)"
    );

    is $other1->p2p_advert_info(id => $my_ad->{id})->{is_visible}, 0, "blocker gets full response for blocked advertiser's ad but is_visible:0";

    cmp_deeply(
        [map { $_->{id} } $other1->p2p_advert_list(type => 'sell')->@*],
        bag($other1_ad->{id}, $other2_ad->{id}),
        "blocked advertiser doesnt see blocker's ad at all (filtered out)"
    );

    delete $me->{_p2p_advertiser_cached};
    is $me->p2p_advertiser_info->{blocked_by_count}, 0, 'blocker has 0 blocked_by_count';

    delete $other1->{_p2p_advertiser_cached};
    is $other1->p2p_advertiser_info->{blocked_by_count},                          1, 'blockee has 1 blocked_by_count';
    is $other1->p2p_advertiser_update()->{blocked_by_count},                      1, 'blocked_by_count returned for empty advertiser update';
    is $other1->p2p_advertiser_update(contact_info => 'xyz')->{blocked_by_count}, 1, 'blocked_by_count returned for actual advertiser update';

    cmp_deeply(
        [map { $_->{id} } $other2->p2p_advert_list(type => 'sell')->@*],
        bag($my_ad->{id}, $other1_ad->{id}, $other2_ad->{id}),
        'third advertiser sees all ads'
    );

    ok $me->p2p_advertiser_info(id => $other1->_p2p_advertiser_cached->{id})->{is_blocked}, 'blocker gets blocked flag in advertiser details';
    ok $me->p2p_advert_info(id => $other1_ad->{id})->{advertiser_details}{is_blocked},      'blocker gets blocked flag in ad details';

    my $ads = $me->p2p_advertiser_adverts;
    ok(!exists $_->{advertiser_details}{is_favourite}, 'is_favourite not present in my ads') for @$ads;
    ok(!exists $_->{advertiser_details}{is_blocked},   'is_blocked not present in my ads')   for @$ads;

    cmp_deeply(
        exception {
            $me->p2p_order_create(
                advert_id   => $other1_ad->{id},
                amount      => 10,
                rule_engine => $rule_engine,
            );
        },
        {error_code => 'AdvertiserBlocked'},
        'Cannot create order on blocked advertisers ad'
    );

    cmp_deeply(
        exception {
            $other1->p2p_order_create(
                advert_id   => $my_ad->{id},
                amount      => 10,
                rule_engine => $rule_engine,
            );
        },
        {error_code => 'InvalidAdvertForOrder'},
        'Blocked advertiser cannot create order on blockers ad'
    );

    my $order = $me->client->p2p_order_create(
        advert_id   => $other2_ad->{id},
        amount      => 10,
        rule_engine => $rule_engine,
    );

    $me->p2p_advertiser_relations(add_blocked => [$other1->_p2p_advertiser_cached->{id}, $other2->_p2p_advertiser_cached->{id}]);
    ok $me->p2p_advertiser_info(id => $other2->_p2p_advertiser_cached->{id})->{is_blocked}, 'blocked advertiser with active order';
    ok $me->p2p_advert_info(id => $other2_ad->{id})->{advertiser_details}{is_blocked},      'blocked ad with active order';

    is(
        exception {
            $me->p2p_order_confirm(id => $order->{id});
            $other2->p2p_order_confirm(id => $order->{id});
        },
        undef,
        'can complete an order after blocking advertiser'
    );

    undef $emitted_events;
    my $update = $me->p2p_advertiser_relations(add_favourites => [$other1->_p2p_advertiser_cached->{id}]);

    cmp_deeply(
        $emitted_events,
        {
            p2p_advertiser_updated => [{client_loginid => $other1->loginid}],
            p2p_adverts_updated    => [{advertiser_id  => $other1->_p2p_advertiser_cached->{id}}]
        },
        'events fired'
    );

    is $update->{favourite_advertisers}[0]{id}, $other1->_p2p_advertiser_cached->{id}, 'blocked is now favourite';
    is $update->{blocked_advertisers}[0]{id},   $other2->_p2p_advertiser_cached->{id}, 'other is still blocked';

    cmp_deeply(
        exception {
            $me->p2p_advertiser_relations(add_blocked => [$me->_p2p_advertiser_cached->{id}])
        },
        {error_code => 'AdvertiserRelationSelf'},
        'Cannot block self'
    );

    cmp_deeply(
        exception {
            $me->p2p_advertiser_relations(remove_blocked => [$me->_p2p_advertiser_cached->{id}])
        },
        {error_code => 'AdvertiserRelationSelf'},
        'Cannot unblock self'
    );

    cmp_deeply(
        exception {
            $me->p2p_advertiser_relations(add_blocked => [-1])
        },
        {error_code => 'InvalidAdvertiserID'},
        'Cannot block invalid advertiser id'
    );

    cmp_deeply(
        exception {
            $me->p2p_advertiser_relations(remove_blocked => [-1])
        },
        {error_code => 'InvalidAdvertiserID'},
        'Cannot unblock invalid advertiser id'
    );

};

done_testing;
