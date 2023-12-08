use strict;
use warnings;

use Test::More;
use Test::MockTime qw(set_fixed_time restore_time);
use Test::MockModule;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use BOM::Config::Redis;
use BOM::Database::ClientDB;
use BOM::User::Script::P2PDailyMaintenance;
use Test::Warn;
use Date::Utility;
use Test::Fatal;

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$config->transaction_verification_countries([]);
$config->transaction_verification_countries_all(0);

my $mock_emit = Test::MockModule->new('BOM::Platform::Event::Emitter');
my $emissions = {};

$mock_emit->mock(
    'emit',
    sub {
        my ($event, $args) = @_;
        push $emissions->{$event}->@*, $args;
        return $mock_emit->original('emit')->(@_);
    });

subtest 'archive old ads' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert();

    $config->archive_ads_days(5);
    BOM::User::Script::P2PDailyMaintenance->new->run;
    $advert = $advertiser->p2p_advert_info(id => $advert->{id});
    ok $advert->{is_active}, 'new ad is active';
    is $advert->{days_until_archive}, 5, 'days_until_archive is 5';
    ok !$emissions->{p2p_archived_ad}, 'Ad not yet archived';

    $advertiser->db->dbic->dbh->do("UPDATE p2p.p2p_advert SET created_time = NOW() - INTERVAL '4 day' WHERE id = ?", undef, $advert->{id});
    BOM::User::Script::P2PDailyMaintenance->new->run;
    $advert = $advertiser->p2p_advert_info(id => $advert->{id});
    ok $advert->{is_active}, 'new ad is active';
    is $advert->{days_until_archive}, 1, 'days_until_archive is 1';
    ok !$emissions->{p2p_archived_ad}, 'Ad not yet archived';

    $advertiser->db->dbic->dbh->do("UPDATE p2p.p2p_advert SET created_time = NOW() - INTERVAL '5 day' WHERE id = ?", undef, $advert->{id});

    $config->archive_ads_days(0);
    BOM::User::Script::P2PDailyMaintenance->new->run;
    ok $advertiser->p2p_advert_info(id => $advert->{id})->{is_active}, 'ad is not deactivated when config days is 0';
    ok !$emissions->{p2p_archived_ad},                                 'Ad not yet archived';

    $emissions = {};
    $config->archive_ads_days(5);
    BOM::User::Script::P2PDailyMaintenance->new->run;
    $advert = $advertiser->p2p_advert_info(id => $advert->{id});
    ok !$advert->{is_active}, 'old ad is deactivated';
    is $advert->{days_until_archive}, undef, 'days_until_archive is undef';

    cmp_deeply(
        $emissions->{p2p_archived_ad},
        [{
                archived_ads       => [$advert->{id}],
                advertiser_loginid => $advertiser->loginid,
            }
        ],
        'Ad archival event emitted for 1 ad'
    );

    cmp_deeply($emissions->{p2p_adverts_updated}, [{advertiser_id => $advertiser->p2p_advertiser_info->{id}}], 'Adverts updated event emitted');

    $emissions = {};
    $advertiser->db->dbic->dbh->do("UPDATE p2p.p2p_advert SET created_time = NOW() - INTERVAL '6 day' WHERE id = ?", undef, $advert->{id});
    BOM::User::Script::P2PDailyMaintenance->new->run;
    $advert = $advertiser->p2p_advert_info(id => $advert->{id});
    ok !$advert->{is_active}, 'ad stays inactive';
    is $advert->{days_until_archive}, undef, 'days_until_archive is undef';

    $advert = $advertiser->p2p_advert_update(
        id        => $advert->{id},
        is_active => 1
    );
    is $advert->{days_until_archive}, undef, 'days_until_archive is undef until cron runs';
    BOM::User::Script::P2PDailyMaintenance->new->run;
    is $advertiser->p2p_advert_info(id => $advert->{id})->{days_until_archive}, 5, '5 after cron runs';

    set_fixed_time(Date::Utility->new->plus_time_interval('10d')->iso8601);
    is $advertiser->p2p_advert_info(id => $advert->{id})->{days_until_archive}, 0, '0 after date passed';

    BOM::Test::Helper::P2P::create_order(advert_id => $advert->{id});
    is $advertiser->p2p_advert_info(id => $advert->{id})->{days_until_archive}, undef, 'undef after order created';

    restore_time();

    subtest 'Multiple archived ads' => sub {

        my ($advertiser2, $advert2)   = BOM::Test::Helper::P2P::create_advert();
        my ($advertiser3, $advert3)   = BOM::Test::Helper::P2P::create_advert();
        my ($advertiser4, $advert4)   = BOM::Test::Helper::P2P::create_advert();
        my (undef,        $advert4_2) = BOM::Test::Helper::P2P::create_advert(
            client         => $advertiser4,
            local_currency => 'pyg'
        );

        $config->archive_ads_days(3);
        BOM::User::Script::P2PDailyMaintenance->new->run;

        ok !$emissions->{p2p_archived_ad}, 'Ads not yet archived';
        ok $advertiser2->p2p_advert_info(id => $advert2->{id})->{is_active},   'ad2 stays active';
        ok $advertiser3->p2p_advert_info(id => $advert3->{id})->{is_active},   'ad3 stays active';
        ok $advertiser4->p2p_advert_info(id => $advert4->{id})->{is_active},   'ad4 stays active';
        ok $advertiser4->p2p_advert_info(id => $advert4_2->{id})->{is_active}, 'ad4_2 stays active';

        $advertiser2->db->dbic->dbh->do("UPDATE p2p.p2p_advert SET created_time = NOW() - INTERVAL '3 day' WHERE id = ?", undef, $advert2->{id});
        $advertiser4->db->dbic->dbh->do("UPDATE p2p.p2p_advert SET created_time = NOW() - INTERVAL '3 day' WHERE id = ?", undef, $advert4->{id});
        $advertiser4->db->dbic->dbh->do("UPDATE p2p.p2p_advert SET created_time = NOW() - INTERVAL '3 day' WHERE id = ?", undef, $advert4_2->{id});

        $emissions = {};
        BOM::User::Script::P2PDailyMaintenance->new->run;
        cmp_bag $emissions->{p2p_archived_ad},
            [{
                archived_ads       => [$advert2->{id}],
                advertiser_loginid => $advertiser2->loginid,
            },
            {
                archived_ads       => [sort ($advert4->{id}, $advert4_2->{id})],
                advertiser_loginid => $advertiser4->loginid,
            }
            ],
            'Ad archival event emitted twice';

        cmp_bag $emissions->{p2p_adverts_updated},
            [{advertiser_id => $advertiser2->p2p_advertiser_info->{id}}, {advertiser_id => $advertiser4->p2p_advertiser_info->{id}}],
            '2 adverts updated event emitted';

        ok !$advertiser2->p2p_advert_info(id => $advert2->{id})->{is_active},   'ad2 was shut down';
        ok $advertiser3->p2p_advert_info(id  => $advert3->{id})->{is_active},   'ad3 stays active';
        ok !$advertiser4->p2p_advert_info(id => $advert4->{id})->{is_active},   'ad4 was shut down';
        ok !$advertiser4->p2p_advert_info(id => $advert4_2->{id})->{is_active}, 'ad4_2 was shut down';
    }
};

subtest 'refresh advertiser completion rates' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');
    my ($client,     $order)  = BOM::Test::Helper::P2P::create_order(advert_id => $advert->{id});
    $client->p2p_order_confirm(id => $order->{id});
    $advertiser->p2p_order_confirm(id => $order->{id});

    # this will change completion rate when it's recalculated
    $advertiser->db->dbic->dbh->do('UPDATE p2p.p2p_advertiser_totals_daily SET complete_total = complete_total+1 WHERE advertiser_id = ?',
        undef, $advertiser->p2p_advertiser_info->{id});

    BOM::User::Script::P2PDailyMaintenance->new->run;
    cmp_ok $advertiser->p2p_advert_info(id => $advert->{id})->{advertiser_details}{total_completion_rate}, '==', 100, 'not updated with recent order';

    $advertiser->db->dbic->dbh->do(
        "UPDATE p2p.p2p_transaction SET transaction_time = transaction_time - INTERVAL '2 day' WHERE type = 'order_complete_payment' and order_id = ?",
        undef, $order->{id});

    BOM::User::Script::P2PDailyMaintenance->new->run;
    cmp_ok $advertiser->p2p_advert_info(id => $advert->{id})->{advertiser_details}{total_completion_rate}, '==', 50, 'updated with older order';
};

subtest 'prune old online entries' => sub {
    my $redis = BOM::Config::Redis->redis_p2p_write;
    set_fixed_time(Date::Utility->new('2000-01-01')->epoch);
    $redis->zadd('P2P::USERS_ONLINE', time, 'CR001::za');

    set_fixed_time(Date::Utility->new('2000-06-30')->epoch);
    BOM::User::Script::P2PDailyMaintenance->new->run;

    ok $redis->zscore('P2P::USERS_ONLINE', 'CR001::za'), 'key still there after 5 months';

    set_fixed_time(Date::Utility->new('2000-07-01')->epoch);
    BOM::User::Script::P2PDailyMaintenance->new->run;

    ok !$redis->zscore('P2P::USERS_ONLINE', 'CR001::za'), 'key deleted after 6 months';
};

subtest 'delete old ads' => sub {
    my $db = BOM::Database::ClientDB->new({broker_code => 'CR'})->db->dbic->dbh;
    $db->do('UPDATE p2p.p2p_advert SET is_deleted = TRUE');
    restore_time();
    $config->archive_ads_days(0);
    $config->delete_ads_days(10);

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert();
    my $id = $advert->{id};

    $db->do("UPDATE p2p.p2p_advert SET created_time = NOW() - '1 year'::INTERVAL, is_active = FALSE WHERE id = $id");

    BOM::User::Script::P2PDailyMaintenance->new->run;
    ok $advertiser->p2p_advert_info(id => $id), 'ad is not deleted with recent deactivation';

    $db->do("UPDATE audit.p2p_advert SET stamp = NOW() - '1 year'::INTERVAL WHERE id = $id");
    $db->do("UPDATE audit.p2p_advert SET stamp = NOW() - '20 day'::INTERVAL WHERE id = $id AND NOT is_active");

    BOM::User::Script::P2PDailyMaintenance->new->run;
    is $advertiser->p2p_advert_info(id => $id), undef, 'ad is deleted after older deactivation';

    ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert();
    $id = $advert->{id};
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(advert_id => $id);

    $db->do("UPDATE p2p.p2p_advert SET created_time = NOW() - '1 year'::INTERVAL, is_active = FALSE WHERE id = $id");
    $db->do("UPDATE audit.p2p_advert SET stamp = NOW() - '1 year'::INTERVAL WHERE id = $id");
    $db->do("UPDATE audit.p2p_advert SET stamp = NOW() - '20 day'::INTERVAL WHERE id = $id AND NOT is_active");

    BOM::User::Script::P2PDailyMaintenance->new->run;
    ok $advertiser->p2p_advert_info(id => $id), 'ad is not deleted with recent order';

    $db->do("UPDATE p2p.p2p_order SET created_time = NOW() - '20 day'::INTERVAL, status = 'completed' WHERE id = " . $order->{id});

    BOM::User::Script::P2PDailyMaintenance->new->run;
    is $advertiser->p2p_advert_info(id => $id), undef, 'ad is deleted with older order completed order';

    $config->delete_ads_days(0);

    ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert();
    $id = $advert->{id};
    $db->do("UPDATE p2p.p2p_advert SET created_time = NOW() - '1 year'::INTERVAL, is_active = FALSE WHERE id = $id");
    $db->do("UPDATE audit.p2p_advert SET stamp = NOW() - '1 year'::INTERVAL WHERE id = $id");
    $db->do("UPDATE audit.p2p_advert SET stamp = NOW() - '20 day'::INTERVAL WHERE id = $id AND NOT is_active");

    BOM::User::Script::P2PDailyMaintenance->new->run;
    ok $advertiser->p2p_advert_info(id => $id), 'ad is not deleted when setting is 0';
};

done_testing;
