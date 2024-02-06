use strict;
use warnings;

use Test::More;
use Test::Deep;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test test_schema/;
use await;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Platform::Token::API;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use Guard;
use JSON::MaybeXS;
use List::Util qw(first);

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
my $json = JSON::MaybeXS->new;

# We need to restore previous values when tests is done
my %init_config_values = (
    'system.suspend.p2p'     => $app_config->system->suspend->p2p,
    'payments.p2p.enabled'   => $app_config->payments->p2p->enabled,
    'payments.p2p.available' => $app_config->payments->p2p->available,
);

$app_config->set({'system.suspend.p2p'     => 0});
$app_config->set({'payments.p2p.enabled'   => 1});
$app_config->set({'payments.p2p.available' => 1});

scope_guard {
    for my $key (keys %init_config_values) {
        $app_config->set({$key => $init_config_values{$key}});
    }
};

my $t = build_wsapi_test();

BOM::Test::Helper::P2P::bypass_sendbird();

my ($me, $my_ad) = BOM::Test::Helper::P2P::create_advert();
my $my_token = BOM::Platform::Token::API->new->create_token($me->loginid, 'test', ['payments']);
$t->await::authorize({authorize => $my_token});

subtest 'trade partners' => sub {
    my ($partner1, $partner1_ad) = BOM::Test::Helper::P2P::create_advert();
    my ($partner2, $partner2_ad) = BOM::Test::Helper::P2P::create_advert();

    my $resp = $t->await::p2p_advertiser_list({
        p2p_advertiser_list => 1,
        trade_partners      => 1
    });
    test_schema('p2p_advertiser_list', $resp);

    $resp = $t->await::p2p_advertiser_relations({
            p2p_advertiser_relations => 1,
            add_blocked              => [$partner1->_p2p_advertiser_cached->{id}]});
    test_schema('p2p_advertiser_relations', $resp);

    $resp = $t->await::p2p_advertiser_list({
        p2p_advertiser_list => 1,
        trade_partners      => 1
    });
    test_schema('p2p_advertiser_list', $resp);

    ok $resp->{p2p_advertiser_list}->{list}->[0]->{is_blocked},          'indicates trade partner is blocked correctly';
    ok !$resp->{p2p_advertiser_list}->{list}->[0]->{first_name},         'indicates trade partner\'s first_name correctly';
    ok !$resp->{p2p_advertiser_list}->{list}->[0]->{last_name},          'indicates trade partner\'s last_name correctly';
    ok !$resp->{p2p_advertiser_list}->{list}->[0]->{basic_verification}, 'indicates trade partner\'s basic_verification correctly';
    ok !$resp->{p2p_advertiser_list}->{list}->[0]->{full_verification},  'indicates trade partner\'s full_verification correctly';

    $partner1->p2p_advertiser_update(show_name => 1);

    $resp = $t->await::p2p_advertiser_list({
        p2p_advertiser_list => 1,
        trade_partners      => 1
    });
    test_schema('p2p_advertiser_list', $resp);

    ok $resp->{p2p_advertiser_list}->{list}->[0]->{is_blocked}, 'indicates trade partner is blocked correctly';
    is $resp->{p2p_advertiser_list}->{list}->[0]->{first_name}, 'bRaD', 'indicates trade partner\'s first_name correctly';
    is $resp->{p2p_advertiser_list}->{list}->[0]->{last_name},  'pItT', 'indicates trade partner\'s last_name correctly';

    $partner1->status->set('age_verification', 'system', 'testing');
    $partner1->client->set_authentication('ID_ONLINE', {status => 'pass'});

    $resp = $t->await::p2p_advertiser_list({
        p2p_advertiser_list => 1,
        trade_partners      => 1
    });
    test_schema('p2p_advertiser_list', $resp);

    ok $resp->{p2p_advertiser_list}->{list}->[0]->{is_blocked}, 'indicates trade partner is blocked correctly';
    is $resp->{p2p_advertiser_list}->{list}->[0]->{first_name},         'bRaD', 'indicates trade partner\'s first_name correctly';
    is $resp->{p2p_advertiser_list}->{list}->[0]->{last_name},          'pItT', 'indicates trade partner\'s last_name correctly';
    is $resp->{p2p_advertiser_list}->{list}->[0]->{basic_verification}, 1,      'indicates trade partner\'s basic_verification correctly';
    is $resp->{p2p_advertiser_list}->{list}->[0]->{full_verification},  1,      'indicates trade partner\'s full_verification correctly';

    $resp = $t->await::p2p_advertiser_info({
            p2p_advertiser_info => 1,
            id                  => $partner1->_p2p_advertiser_cached->{id}});
    test_schema('p2p_advertiser_info', $resp);

    $resp = $t->await::p2p_order_create({
        p2p_order_create => 1,
        advert_id        => $partner1_ad->{id},
        amount           => 10
    });
    test_schema('p2p_order_create', $resp);

    $resp = $t->await::p2p_advertiser_list({
        p2p_advertiser_list => 1,
        trade_partners      => 1
    });
    test_schema('p2p_advertiser_list', $resp);

    $resp = $t->await::p2p_order_create({
        p2p_order_create => 1,
        advert_id        => $partner2_ad->{id},
        amount           => 10
    });
    test_schema('p2p_order_create', $resp);

    $resp = $t->await::p2p_advertiser_relations({
            p2p_advertiser_relations => 1,
            add_blocked              => [$partner2->_p2p_advertiser_cached->{id}],
            remove_blocked           => [$partner1->_p2p_advertiser_cached->{id}],
            add_favourites           => [$partner1->_p2p_advertiser_cached->{id}]});
    test_schema('p2p_advertiser_relations', $resp);

    $resp = $t->await::p2p_advertiser_list({
        p2p_advertiser_list => 1,
        trade_partners      => 1
    });
    test_schema('p2p_advertiser_list', $resp);

    foreach my $adv ($resp->{p2p_advertiser_list}->{list}->@*) {
        delete $adv->{created_time};
    }

    my $online_time = time();

    is scalar $resp->{p2p_advertiser_list}->{list}->@*, 2, '2 listing';
    cmp_deeply(
        $resp->{p2p_advertiser_list}->{list},
        [{
                advert_rates               => undef,
                basic_verification         => 1,
                buy_completion_rate        => undef,
                buy_orders_amount          => '0.00',
                buy_orders_count           => 0,
                buy_time_avg               => undef,
                cancel_time_avg            => undef,
                default_advert_description => '',
                first_name                 => 'bRaD',
                full_verification          => 1,
                id                         => 2,
                is_approved                => 1,
                is_blocked                 => 0,
                is_favourite               => 1,
                is_listed                  => 1,
                is_online                  => 1,
                is_recommended             => 0,
                last_name                  => 'pItT',
                last_online_time           => num($online_time, 3),
                name                       => 'test advertiser 102',
                partner_count              => 0,
                rating_average             => undef,
                rating_count               => 0,
                recommended_average        => undef,
                recommended_count          => undef,
                release_time_avg           => undef,
                sell_completion_rate       => undef,
                sell_orders_amount         => '0.00',
                sell_orders_count          => 0,
                total_completion_rate      => undef,
                total_orders_count         => 0,
                total_turnover             => '0.00'
            },
            {
                advert_rates               => undef,
                basic_verification         => 0,
                buy_completion_rate        => undef,
                buy_orders_amount          => '0.00',
                buy_orders_count           => 0,
                buy_time_avg               => undef,
                cancel_time_avg            => undef,
                default_advert_description => '',
                full_verification          => 0,
                id                         => 3,
                is_approved                => 1,
                is_blocked                 => 1,
                is_favourite               => 0,
                is_listed                  => 1,
                is_online                  => 1,
                is_recommended             => 0,
                last_online_time           => num($online_time, 3),
                name                       => 'test advertiser 103',
                partner_count              => 0,
                rating_average             => undef,
                rating_count               => 0,
                recommended_average        => undef,
                recommended_count          => undef,
                release_time_avg           => undef,
                sell_completion_rate       => undef,
                sell_orders_amount         => '0.00',
                sell_orders_count          => 0,
                total_completion_rate      => undef,
                total_orders_count         => 0,
                total_turnover             => '0.00'
            }]);

    #negative offset
    $resp = $t->await::p2p_advertiser_list({
        p2p_advertiser_list => 1,
        trade_partners      => 1,
        offset              => -1
    });
    test_schema('p2p_advertiser_list', $resp);
    is($resp->{msg_type},         'p2p_advertiser_list');
    is($resp->{error}->{code},    'InputValidationFailed',           "Input field is invalid");
    is($resp->{error}->{message}, 'Input validation failed: offset', "Checked that validation failed for offset");
};

$t->finish_ok;

done_testing();
