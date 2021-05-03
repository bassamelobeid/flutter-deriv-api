use strict;
use warnings;

use Test::More;
use Test::MockTime qw(set_fixed_time restore_time);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use BOM::User::Script::P2PDailyMaintenance;
use Test::Warn;
use Date::Utility;

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();

subtest 'archive old ads' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert();

    BOM::Config::Runtime->instance->app_config->payments->p2p->archive_ads_days(5);
    BOM::User::Script::P2PDailyMaintenance->new->run;
    $advert = $advertiser->p2p_advert_info(id => $advert->{id});
    ok $advert->{is_active}, 'new ad is active';
    is $advert->{days_until_archive}, 5, 'days_until_archive is 5';

    $advertiser->db->dbic->dbh->do("UPDATE p2p.p2p_advert SET created_time = NOW() - INTERVAL '4 day' WHERE id = ?", undef, $advert->{id});
    BOM::User::Script::P2PDailyMaintenance->new->run;
    $advert = $advertiser->p2p_advert_info(id => $advert->{id});
    ok $advert->{is_active}, 'new ad is active';
    is $advert->{days_until_archive}, 1, 'days_until_archive is 1';

    $advertiser->db->dbic->dbh->do("UPDATE p2p.p2p_advert SET created_time = NOW() - INTERVAL '5 day' WHERE id = ?", undef, $advert->{id});

    BOM::Config::Runtime->instance->app_config->payments->p2p->archive_ads_days(0);
    BOM::User::Script::P2PDailyMaintenance->new->run;
    ok $advertiser->p2p_advert_info(id => $advert->{id})->{is_active}, 'ad is not deactivated when config days is 0';

    BOM::Config::Runtime->instance->app_config->payments->p2p->archive_ads_days(5);
    BOM::User::Script::P2PDailyMaintenance->new->run;
    $advert = $advertiser->p2p_advert_info(id => $advert->{id});
    ok !$advert->{is_active}, 'old ad is deactivated';
    is $advert->{days_until_archive}, undef, 'days_until_archive is undef';

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
