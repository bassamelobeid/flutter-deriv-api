use strict;
use warnings;

use Test::More;
use Test::Fatal qw(exception lives_ok);
use Test::Deep;
use JSON::MaybeUTF8 qw(:v1);

use BOM::Test::Helper::P2P;
use BOM::Test::Helper::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();

my $p2p_config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$p2p_config->country_advert_config(encode_json_utf8({}));

my $rule_engine = BOM::Rules::Engine->new();

my $advertiser = BOM::Test::Helper::P2P::create_advertiser(
    balance        => 100,
    client_details => {residence => 'id'});
my $client_id = BOM::Test::Helper::P2P::create_advertiser(client_details => {residence => 'id'});
my $client_za = BOM::Test::Helper::P2P::create_advertiser(client_details => {residence => 'za'});

my $ad = $advertiser->p2p_advert_create(
    amount              => 100,
    max_order_amount    => 100,
    min_order_amount    => 1,
    payment_method      => 'bank_transfer',
    payment_info        => 'x',
    contact_info        => 'x',
    rate                => 1,
    rate_type           => 'fixed',
    type                => 'sell',
    min_completion_rate => 95.5555,
    min_rating          => 4.5555,
    min_join_days       => 15,
    eligible_countries  => ['za', 'ng'],
);

cmp_ok($ad->{min_completion_rate}, 'eq', '95.6', 'min_completion_rate returned from p2p_advert_create');
cmp_ok($ad->{min_rating},          'eq', '4.56', 'min_rating returned from p2p_advert_create');
cmp_ok($ad->{min_join_days},       'eq', '15',   'min_join_days returned from p2p_advert_create');
cmp_deeply($ad->{eligible_countries}, ['ng', 'za'], 'eligible_countries returned from p2p_advert_create');
ok(!exists $ad->{is_eligible} && !exists $ad->{eligibilty_status}, 'is_eligible and eligibilty_status not returned from p2p_advert_create');

my $id = $ad->{id};

cmp_ok(
    $client_id->p2p_advert_list(
        local_currency  => 'IDR',
        hide_ineligible => 1
    )->@*,
    '==', 0,
    'ineligible ad can be hidden'
);

($ad) = $client_id->p2p_advert_list(local_currency => 'IDR')->@*;
cmp_ok($ad->{is_eligible}, '==', 0, 'ineligible client gets is_eligible=0 from p2p_advert_list');
cmp_deeply(
    $ad->{eligibility_status},
    [qw(completion_rate country join_date rating_average)],
    'ineligible client gets all values for eligiblility_status from p2p_advert_list'
);

($ad) = $client_id->p2p_advert_info(id => $id);
cmp_ok($ad->{is_eligible}, '==', 0, 'ineligible client gets is_eligible=0 from p2p_advert_info');
cmp_deeply(
    $ad->{eligibility_status},
    [qw(completion_rate country join_date rating_average)],
    'ineligible client gets all values for eligiblility_status from p2p_advert_info'
);

cmp_deeply(
    exception { $client_id->p2p_order_create(advert_id => $id, amount => 10, rule_engine => $rule_engine) },
    {error_code => 'AdvertCounterpartyIneligible'},
    'fully ineligible client cannot place order'
);

BOM::Test::Helper::P2P::set_advertiser_created_time_by_day($client_id, -30);
BOM::Test::Helper::P2P::set_advertiser_completion_rate($client_id, 0.96);
BOM::Test::Helper::P2P::set_advertiser_rating_average($client_id, 4.6);

($ad) = $client_id->p2p_advert_list(local_currency => 'IDR')->@*;
cmp_ok($ad->{is_eligible}, '==', 0, 'client only ineligible for country gets is_eligible=0 from p2p_advert_list');
cmp_deeply($ad->{eligibility_status}, [qw(country)], 'client only ineligible for country eligibility_status from p2p_advert_list');

($ad) = $client_id->p2p_advert_info(id => $id);
cmp_ok($ad->{is_eligible}, '==', 0, 'client only ineligible for country gets is_eligible=0 from p2p_advert_info');
cmp_deeply($ad->{eligibility_status}, [qw(country)], 'client only ineligible for country eligibility_status from p2p_advert_info');

cmp_deeply(
    exception { $client_id->p2p_order_create(advert_id => $id, amount => 10, rule_engine => $rule_engine) },
    {error_code => 'AdvertCounterpartyIneligible'},
    'client only ineligible for country cannot place order'
);

BOM::Test::Helper::P2P::set_advertiser_completion_rate($client_za, 0.96);
BOM::Test::Helper::P2P::set_advertiser_rating_average($client_za, 4.6);

($ad) = $client_za->p2p_advert_info(id => $id);
cmp_ok($ad->{is_eligible}, '==', 0, 'client only ineligible for join date is_eligible=0');
cmp_deeply($ad->{eligibility_status}, [qw(join_date)], 'client only ineligible for join date eligibility_status');

cmp_deeply(
    exception { $client_za->p2p_order_create(advert_id => $id, amount => 10, rule_engine => $rule_engine) },
    {error_code => 'AdvertCounterpartyIneligible'},
    'client only ineligible for join date cannot place order'
);

BOM::Test::Helper::P2P::set_advertiser_created_time_by_day($client_za, -30);
BOM::Test::Helper::P2P::set_advertiser_completion_rate($client_za, 0.95);

($ad) = $client_za->p2p_advert_info(id => $id);
cmp_ok($ad->{is_eligible}, '==', 0, 'client only ineligible for completion rate is_eligible=0');
cmp_deeply($ad->{eligibility_status}, [qw(completion_rate)], 'client only ineligible for completion rate eligibility_status');

cmp_deeply(
    exception { $client_za->p2p_order_create(advert_id => $id, amount => 10, rule_engine => $rule_engine) },
    {error_code => 'AdvertCounterpartyIneligible'},
    'client only ineligible for completion rate cannot place order'
);

BOM::Test::Helper::P2P::set_advertiser_completion_rate($client_za, 0.96);
BOM::Test::Helper::P2P::set_advertiser_rating_average($client_za, 4.5);

($ad) = $client_za->p2p_advert_info(id => $id);
cmp_ok($ad->{is_eligible}, '==', 0, 'client only ineligible for rating is_eligible=0');
cmp_deeply($ad->{eligibility_status}, [qw(rating_average)], 'client only ineligible for rating_average eligibility_status');

cmp_deeply(
    exception { $client_za->p2p_order_create(advert_id => $id, amount => 10, rule_engine => $rule_engine) },
    {error_code => 'AdvertCounterpartyIneligible'},
    'client only ineligible for rating_average cannot place order'
);

BOM::Test::Helper::P2P::set_advertiser_rating_average($client_za, 4.6);
($ad) = $client_za->p2p_advert_info(id => $id);
cmp_ok($ad->{is_eligible}, '==', 1, 'is_eligible=1 for eligible client');
ok(!exists $ad->{eligibility_status}, 'eligiblility_status does not exist for eligible client');

is(exception { $client_za->p2p_order_create(advert_id => $id, amount => 10, rule_engine => $rule_engine) }, undef, 'eligible client can place order');

BOM::Test::Helper::P2P::set_advertiser_created_time_by_day($client_id, -5);
BOM::Test::Helper::P2P::set_advertiser_completion_rate($client_id, 0.9);
BOM::Test::Helper::P2P::set_advertiser_rating_average($client_id, 4);
cmp_deeply $client_id->p2p_advert_info(id => $id)->{eligibility_status}, [qw(completion_rate country join_date rating_average)],
    'client became ineligible for everything';

cmp_ok $advertiser->p2p_advert_update(
    id                  => $id,
    min_completion_rate => 90
)->{min_completion_rate}, 'eq', '90.0', 'set completion rate to value';
cmp_deeply $client_id->p2p_advert_info(id => $id)->{eligibility_status}, [qw(country join_date rating_average)],
    'client became eligible for completion rate';

ok !exists $advertiser->p2p_advert_update(
    id                  => $id,
    min_completion_rate => undef
)->{min_completion_rate}, 'set completion rate to undef';
cmp_deeply $client_id->p2p_advert_info(id => $id)->{eligibility_status}, [qw(country join_date rating_average)],
    'client stays eligible for completion rate';

cmp_ok $advertiser->p2p_advert_update(
    id         => $id,
    min_rating => 4
)->{min_rating}, 'eq', '4.00', 'set rating avg to value';
cmp_deeply $client_id->p2p_advert_info(id => $id)->{eligibility_status}, [qw(country join_date)], 'client became eligible for rating avg';

ok !exists $advertiser->p2p_advert_update(
    id         => $id,
    min_rating => undef
)->{min_rating}, 'set rating avg to undef';
cmp_deeply $client_id->p2p_advert_info(id => $id)->{eligibility_status}, [qw(country join_date)], 'client stays eligible for rating avg';

cmp_ok $advertiser->p2p_advert_update(
    id            => $id,
    min_join_days => 5
)->{min_join_days}, 'eq', '5', 'set join days to value';
cmp_deeply $client_id->p2p_advert_info(id => $id)->{eligibility_status}, [qw(country)], 'client became eligible for join date';

ok !exists $advertiser->p2p_advert_update(
    id            => $id,
    min_join_days => undef
)->{min_join_days}, 'set join days to undef';
cmp_deeply $client_id->p2p_advert_info(id => $id)->{eligibility_status}, [qw(country)], 'client stays eligible for join date';

cmp_deeply $advertiser->p2p_advert_update(
    id                 => $id,
    eligible_countries => ['za', 'id'])->{eligible_countries}, ['id', 'za'], 'set eligible_countries to a value';
is $client_id->p2p_advert_info(id => $id)->{is_eligible}, 1, 'client became eligible for country';

ok !exists $advertiser->p2p_advert_update(
    id                 => $id,
    eligible_countries => [])->{eligible_countries}, 'empty array sets eligible_countries to undef';
is $client_id->p2p_advert_info(id => $id)->{is_eligible}, 1, 'client stays eligible for country';

cmp_deeply $advertiser->p2p_advert_update(
    id                 => $id,
    eligible_countries => ['za', 'id', 'ng'])->{eligible_countries}, ['id', 'ng', 'za'], 'set eligible_countries to new value';

ok !exists $advertiser->p2p_advert_update(
    id                 => $id,
    eligible_countries => undef
)->{eligible_countries}, 'undef sets eligible_countries to undef';
is $client_id->p2p_advert_info(id => $id)->{is_eligible}, 1, 'client stays eligible for country';

done_testing();
