use strict;
use warnings;

use Test::More;
use Test::MockTime qw(set_fixed_time restore_time);
use Test::MockModule;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use BOM::User::Script::P2PDailyMaintenance;
use Test::Warn;
use Date::Utility;
use Test::Fatal;

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();

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

    BOM::Config::Runtime->instance->app_config->payments->p2p->archive_ads_days(5);
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

    BOM::Config::Runtime->instance->app_config->payments->p2p->archive_ads_days(0);
    BOM::User::Script::P2PDailyMaintenance->new->run;
    ok $advertiser->p2p_advert_info(id => $advert->{id})->{is_active}, 'ad is not deactivated when config days is 0';
    ok !$emissions->{p2p_archived_ad}, 'Ad not yet archived';

    $emissions = {};
    BOM::Config::Runtime->instance->app_config->payments->p2p->archive_ads_days(5);
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

        BOM::Config::Runtime->instance->app_config->payments->p2p->archive_ads_days(3);
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

done_testing;
