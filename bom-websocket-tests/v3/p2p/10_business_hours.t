use strict;
use warnings;

use Test::More;
use Test::Deep;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test test_schema/;
use await;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::P2P;
use BOM::User::Client;
use BOM::Platform::Token::API;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use JSON::MaybeUTF8 qw(:v1);
use Date::Utility;

my $t = build_wsapi_test();

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

my $client_escrow = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'p2p_escrow@test.com',
});
$client_escrow->account('USD');

$app_config->set({'payments.p2p.enabled'                         => 1});
$app_config->set({'system.suspend.p2p'                           => 0});
$app_config->set({'payments.p2p.available'                       => 1});
$app_config->set({'payments.p2p.restricted_countries'            => []});
$app_config->set({'payments.p2p.available_for_currencies'        => ['usd']});
$app_config->set({'payments.p2p.escrow'                          => [$client_escrow->loginid]});
$app_config->set({'payments.p2p.poa.enabled'                     => 0});
$app_config->set({'payments.p2p.business_hours_minutes_interval' => 15});

BOM::Test::Helper::P2P::bypass_sendbird();

my $dt          = Date::Utility->new;
my $current_min = ($dt->day_of_week * 1440) + ($dt->hour * 60) + $dt->minute;

my $out_of_range = $current_min > 5040 ? 0 : 10065;

my $user = BOM::User->create(
    email          => 'schedule@test.com',
    password       => 'x',
    email_verified => 1,
);

my $advertiser = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    binary_user_id => $user->id,
});

$user->add_client($advertiser);

$advertiser->account('USD');
BOM::Test::Helper::Client::top_up($advertiser, 'USD', 1000);
$advertiser->status->set('age_verification', 'system', 'testing');

my $client = BOM::Test::Helper::P2P::create_advertiser();

my $advertiser_token = BOM::Platform::Token::API->new->create_token($advertiser->loginid, 'test', ['payments']);
my $client_token     = BOM::Platform::Token::API->new->create_token($client->loginid,     'test', ['payments']);

$t->await::authorize({authorize => $advertiser_token});

my $schedule = [{
        start_min => 540,
        end_min   => 1020
    },
    {
        start_min => 1980,
        end_min   => 2460
    }];

my $resp = $t->await::p2p_advertiser_create({
    p2p_advertiser_create => 1,
    name                  => 'bob',
    schedule              => $schedule,
});

cmp_deeply $resp->{p2p_advertiser_create}{schedule}, $schedule, 'create schedule in p2p_advertiser_create';

$resp = $t->await::p2p_advertiser_info({
    p2p_advertiser_info => 1,
});

cmp_deeply $resp->{p2p_advertiser_info}{schedule}, $schedule, 'self gets schedule in p2p_advertiser_info';

$resp = $t->await::p2p_advertiser_update({
    p2p_advertiser_update => 1,
    schedule              => [{start_min => 0, end_min => 1}],
});

is $resp->{error}{code}, 'InvalidScheduleInterval', 'InvalidScheduleInterval error';

$resp = $t->await::p2p_advertiser_update({
    p2p_advertiser_update => 1,
    schedule              => [{start_min => 30, end_min => 15}],
});

is $resp->{error}{code}, 'InvalidScheduleRange', 'InvalidScheduleRange error';

$schedule = [{start_min => $out_of_range, end_min => $out_of_range + 15}];

$resp = $t->await::p2p_advertiser_update({
    p2p_advertiser_update => 1,
    schedule              => $schedule,
});

cmp_deeply $resp->{p2p_advertiser_update}{schedule}, $schedule, 'update schedule in p2p_advertiser_update';
cmp_ok $resp->{p2p_advertiser_update}{is_schedule_available}, '==', 0, 'is_schedule_available is false';

$resp = $t->await::p2p_advert_create({
    p2p_advert_create => 1,
    type              => 'sell',
    min_order_amount  => 1,
    max_order_amount  => 100,
    amount            => 100,
    payment_method    => 'bank_transfer',
    contact_info      => 'x',
    payment_info      => 'x',
    rate              => 1,
});

my $ad = $resp->{p2p_advert_create};
cmp_ok $ad->{advertiser_details}{is_schedule_available}, '==', 0, 'p2p_advert_create advertiser_details/is_schedule_available is false';
cmp_ok $ad->{is_visible},                                '==', 0, 'p2p_advert_create is_visible is false';
cmp_deeply $ad->{visibility_status}, ['advertiser_schedule'], 'p2p_advert_create visibility_status is advertiser_schedule';

$t->await::authorize({authorize => $client_token});

$resp = $t->await::p2p_advert_list({
    p2p_advert_list                  => 1,
    counterparty_type                => 'buy',
    hide_client_schedule_unavailable => 0,
});

cmp_deeply $resp->{p2p_advert_list}{list}, [], 'ad is hidden';

$resp = $t->await::p2p_order_create({
    p2p_order_create => 1,
    advert_id        => $ad->{id},
    amount           => 10,
});

is $resp->{error}{code}, 'AdvertiserScheduleAvailability', 'AdvertiserScheduleAvailability error';

$t->await::authorize({authorize => $advertiser_token});

$resp = $t->await::p2p_advertiser_update({
    p2p_advertiser_update => 1,
    schedule              => undef,
});

ok !exists $resp->{p2p_advertiser_update}{schedule}, 'remove schedule in p2p_advertiser_update';

$t->await::authorize({authorize => $client_token});

$resp = $t->await::p2p_advert_list({
    p2p_advert_list                  => 1,
    counterparty_type                => 'buy',
    hide_client_schedule_unavailable => 1,
});

cmp_deeply [map { $_->{id} } $resp->{p2p_advert_list}{list}->@*], [$ad->{id}], 'ad is shown';

$resp = $t->await::p2p_advertiser_update({
    p2p_advertiser_update => 1,
    schedule              => $schedule,
});

$resp = $t->await::p2p_advert_list({
    p2p_advert_list                  => 1,
    counterparty_type                => 'buy',
    hide_client_schedule_unavailable => 1,
});

cmp_deeply $resp->{p2p_advert_list}{list}, [], 'ad is hidden for client with hide_client_schedule_unavailable=1';

$resp = $t->await::p2p_advert_list({
    p2p_advert_list                  => 1,
    counterparty_type                => 'buy',
    hide_client_schedule_unavailable => 0,
});

cmp_deeply [map { $_->{id} } $resp->{p2p_advert_list}{list}->@*], [$ad->{id}], 'ad is shown to client with hide_client_schedule_unavailable=0';

$resp = $t->await::p2p_order_create({
    p2p_order_create => 1,
    advert_id        => $ad->{id},
    amount           => 10,
});

is $resp->{error}{code}, 'ClientScheduleAvailability', 'ClientScheduleAvailability error';

$t->await::p2p_advertiser_update({
    p2p_advertiser_update => 1,
    schedule              => [],
});

$resp = $t->await::p2p_order_create({
    p2p_order_create => 1,
    advert_id        => $ad->{id},
    amount           => 10,
});

ok !exists $resp->{error}, 'can create order after removing schedule';

done_testing();
