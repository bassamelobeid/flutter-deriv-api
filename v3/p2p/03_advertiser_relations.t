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

subtest 'favourites' => sub {

    my ($fav, $fav_ad) = BOM::Test::Helper::P2P::create_advert();

    my $resp = $t->await::p2p_advertiser_relations({
            p2p_advertiser_relations => 1,
            add_favourites           => [$fav->_p2p_advertiser_cached->{id}]});
    note explain $resp;
    test_schema('p2p_advertiser_relations', $resp);
    my $update = $resp->{p2p_advertiser_relations};
    is $update->{favourite_advertisers}[0]{id}, $fav->_p2p_advertiser_cached->{id}, 'created favourite';

    $resp = $t->await::p2p_advertiser_info({
            p2p_advertiser_info => 1,
            id                  => $fav->_p2p_advertiser_cached->{id}});
    test_schema('p2p_advertiser_info', $resp);
    ok $resp->{p2p_advertiser_info}{is_favourite}, 'get advertiser info for favourite advertiser';

    $resp = $t->await::p2p_advert_list({
        p2p_advert_list   => 1,
        counterparty_type => 'buy',
        favourites_only   => 1
    });
    test_schema('p2p_advert_list', $resp);
    my @ids = map { $_->{id} } $resp->{p2p_advert_list}{list}->@*;
    cmp_deeply(\@ids, [$fav_ad->{id}], 'ad list returns favourites only');

    $resp = $t->await::p2p_advert_info({
            p2p_advert_info => 1,
            id              => $fav_ad->{id}});
    test_schema('p2p_advert_info', $resp);
    ok $resp->{p2p_advert_info}{advertiser_details}{is_favourite}, 'get advert info for favourite advertiser';

    $resp = $t->await::p2p_advertiser_relations({
            p2p_advertiser_relations => 1,
            remove_favourites        => [$fav->_p2p_advertiser_cached->{id}]});
    test_schema('p2p_advertiser_relations', $resp);
    $update = $resp->{p2p_advertiser_relations};
    cmp_deeply($update->{favourite_advertisers}, [], 'remove favourite');
};

subtest 'blocking' => sub {
    my ($bad, $bad_ad) = BOM::Test::Helper::P2P::create_advert();

    my $resp = $t->await::p2p_advertiser_relations({
            p2p_advertiser_relations => 1,
            add_blocked              => [$bad->_p2p_advertiser_cached->{id}]});
    test_schema('p2p_advertiser_relations', $resp);
    my $update = $resp->{p2p_advertiser_relations};
    is $update->{blocked_advertisers}[0]{id}, $bad->_p2p_advertiser_cached->{id}, 'blocked an advertiser';

    $resp = $t->await::p2p_advertiser_info({
            p2p_advertiser_info => 1,
            id                  => $bad->_p2p_advertiser_cached->{id}});
    test_schema('p2p_advertiser_info', $resp);
    ok $resp->{p2p_advertiser_info}{is_blocked}, 'get advertiser info for blocked advertiser';

    $resp = $t->await::p2p_advert_list({
        p2p_advert_list   => 1,
        counterparty_type => 'buy'
    });
    my @blocked_ads = grep { $_->{id} == $bad_ad->{id} } $resp->{p2p_advert_list}{list}->@*;
    ok !@blocked_ads, 'blocked advertisers ad not in ad list';

    $resp = $t->await::p2p_advert_info({
            p2p_advert_info => 1,
            id              => $bad_ad->{id}});
    test_schema('p2p_advert_info', $resp);
    ok $resp->{p2p_advert_info}{advertiser_details}{is_blocked}, 'get advert info for blocked advertiser';

    $resp = $t->await::p2p_advertiser_relations({
            p2p_advertiser_relations => 1,
            remove_blocked           => [$bad->_p2p_advertiser_cached->{id}]});
    test_schema('p2p_advertiser_relations', $resp);
    $update = $resp->{p2p_advertiser_relations};
    cmp_deeply($update->{blocked_advertisers}, [], 'remove blocked');

};

$t->finish_ok;

done_testing();
