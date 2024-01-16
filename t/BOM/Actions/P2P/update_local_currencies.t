use strict;
use warnings;

use Test::More;
use Test::Deep;
use BOM::Event::Actions::P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;

BOM::Test::Helper::P2P::bypass_sendbird();

my $redis = BOM::Config::Redis->redis_p2p();
my $key   = 'P2P::LOCAL_CURRENCIES';
$redis->del($key);

BOM::Event::Actions::P2P::update_local_currencies();

ok $redis->exists($key), 'key exists';
is $redis->get($key), '', 'key is empty if no ads';

my ($advertiser, $ad_ngn) = BOM::Test::Helper::P2P::create_advert(local_currency => 'NGN');
BOM::Event::Actions::P2P::update_local_currencies();
is $redis->get($key), 'NGN', 'key set after ad created';

BOM::Test::Helper::P2P::create_advert(local_currency => 'IDR');
BOM::Event::Actions::P2P::update_local_currencies();
cmp_bag [split(',', $redis->get($key))], ['NGN', 'IDR'], 'key updated after 2nd ad created';

$advertiser->p2p_advert_update(
    id        => $ad_ngn->{id},
    is_active => 0
);

BOM::Event::Actions::P2P::update_local_currencies();
is $redis->get($key), 'IDR', 'key updated after ad disabled';

BOM::Test::Helper::P2P::create_advert(local_currency => 'AAD');
BOM::Event::Actions::P2P::update_local_currencies();
is $redis->get($key), 'IDR', 'AAD is ignored';

BOM::Test::Helper::P2P::create_advert(local_currency => 'ZAR');
BOM::Event::Actions::P2P::update_local_currencies();
cmp_bag [split(',', $redis->get($key))], ['ZAR', 'IDR'], 'key updated after 3rd ad created';

done_testing();
