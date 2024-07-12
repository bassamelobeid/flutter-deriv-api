use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;

use BOM::Event::Actions::P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;

BOM::Test::Helper::P2P::bypass_sendbird();

my @metrics = ();
my $mock_dd = Test::MockModule->new('BOM::Event::Actions::P2P');
$mock_dd->redefine(
    stats_timing => sub {
        push @metrics, @_;
    });

my $emitted_events;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock('emit' => sub { push $emitted_events->{$_[0]}->@*, $_[1] });

my $redis = BOM::Config::Redis->redis_p2p();
my $key   = 'P2P::LOCAL_CURRENCIES';
$redis->del($key);

BOM::Event::Actions::P2P::update_local_currencies();

ok !$redis->exists($key), 'key is not created since there is no ads';
is $emitted_events->{p2p_settings_updated}, undef, 'p2p_settings_updated event not emitted because there are no ads';
is @metrics,                                0,     'no DD metric sent because there are no ads';

my ($advertiser, $ad_inr) = BOM::Test::Helper::P2P::create_advert(local_currency => 'INR');
$emitted_events = {};
@metrics        = ();
BOM::Event::Actions::P2P::update_local_currencies();

ok $redis->exists($key), 'key exists';
is $redis->get($key), 'INR', 'key set after ad created';
cmp_deeply($emitted_events->{p2p_settings_updated}, [{}], 'p2p_settings_updated event emitted because new local currency:INR added');
cmp_deeply(
    {@metrics},
    {'p2p.update_local_currency.processing_time', re('\d+(\.\d+)?')},
    'Correct DD metric sent to record processing time of updating local currency'
);

my ($advertiser2, $ad_inr2) = BOM::Test::Helper::P2P::create_advert(local_currency => 'INR');
$emitted_events = {};
@metrics        = ();
BOM::Event::Actions::P2P::update_local_currencies();

is $redis->get($key),                       'INR', 'value unchanged';
is $emitted_events->{p2p_settings_updated}, undef, 'p2p_settings_updated event not emitted because there is no change in local currency';
is @metrics,                                0,     'no DD metric sent because there is no change in local currencies';

BOM::Test::Helper::P2P::create_advert(local_currency => 'IDR');
$emitted_events = {};
@metrics        = ();
BOM::Event::Actions::P2P::update_local_currencies();

cmp_bag [split(',', $redis->get($key))], ['INR', 'IDR'], 'key updated after 2nd ad created';
cmp_deeply($emitted_events->{p2p_settings_updated}, [{}], 'p2p_settings_updated event emitted because new local currency:IDR added');
cmp_deeply(
    {@metrics},
    {'p2p.update_local_currency.processing_time', re('\d+(\.\d+)?')},
    'Correct DD metric sent to record processing time of updating local currency'
);

$advertiser->p2p_advert_update(
    id        => $ad_inr->{id},
    is_active => 0
);
$advertiser2->p2p_advert_update(
    id     => $ad_inr2->{id},
    delete => 1
);
$emitted_events = {};
@metrics        = ();
BOM::Event::Actions::P2P::update_local_currencies();

is $redis->get($key), 'IDR', 'key updated after INR ads are either deactived or/and deleted';
BOM::Event::Actions::P2P::update_local_currencies();
cmp_deeply($emitted_events->{p2p_settings_updated}, [{}], 'p2p_settings_updated event emitted because existing local currency:INR removed');
cmp_deeply(
    {@metrics},
    {'p2p.update_local_currency.processing_time', re('\d+(\.\d+)?')},
    'Correct DD metric sent to record processing time of updating local currency'
);

BOM::Test::Helper::P2P::create_advert(local_currency => 'AAD');
$emitted_events = {};
@metrics        = ();
BOM::Event::Actions::P2P::update_local_currencies();

is $redis->get($key), 'IDR', 'AAD is ignored';
is $emitted_events->{p2p_settings_updated}, undef,
    'p2p_settings_updated event not emitted because there is no change in local currency as new AAD ad is ignored';
is @metrics, 0, 'no DD metric sent because there is no change in local currencies as new AAD ad is ignored';

BOM::Test::Helper::P2P::create_advert(local_currency => 'ZAR');
$emitted_events = {};
@metrics        = ();
BOM::Event::Actions::P2P::update_local_currencies();

cmp_bag [split(',', $redis->get($key))], ['ZAR', 'IDR'], 'key updated after 3rd ad created';
cmp_deeply($emitted_events->{p2p_settings_updated}, [{}], 'p2p_settings_updated event emitted because new local currency:ZAR added');
cmp_deeply(
    {@metrics},
    {'p2p.update_local_currency.processing_time', re('\d+(\.\d+)?')},
    'Correct DD metric sent to record processing time of updating local currency'
);

done_testing();
