use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warn;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::P2PWithClient;
use BOM::Config::Runtime;
use BOM::Rules::Engine;
use P2P;
use Test::Fatal;
use Test::Exception;
use Guard;

BOM::Test::Helper::P2PWithClient::bypass_sendbird();
BOM::Test::Helper::P2PWithClient::create_escrow();
BOM::Test::Helper::P2PWithClient::populate_trade_band_db();

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$config->block_trade->enabled(1);
$config->block_trade->maximum_advert(20000);

my $advertiser = BOM::Test::Helper::P2PWithClient::create_advertiser(balance => 10000);
my $client     = BOM::Test::Helper::P2PWithClient::create_advertiser;

my %params = (
    amount           => 20000,
    max_order_amount => 10000,
    min_order_amount => 1000,
    payment_method   => 'bank_transfer',
    payment_info     => 'x',
    contact_info     => 'x',
    rate             => 1.0,
    rate_type        => 'fixed',
    type             => 'sell',
    block_trade      => 1,
);

cmp_deeply(
    exception {
        P2P->new(client => $advertiser)->p2p_advert_create(%params);
    },
    {
        error_code => 'BlockTradeNotAllowed',
    },
    'Cannot create block trade ad if in wrong band'
);

ok !exists $advertiser->p2p_advertiser_info->{block_trade}, 'block_trade does not exist in p2p_advertiser_info';

$advertiser->db->dbic->dbh->do(
    "UPDATE p2p.p2p_advertiser SET trade_band = 'block_trade_medium' WHERE id = " . $advertiser->p2p_advertiser_info->{id});
delete $advertiser->{_p2p_advertiser_cached};

# block_trade_medium band has limits 1000-10000
cmp_deeply(
    $advertiser->p2p_advertiser_info->{block_trade},
    {
        min_order_amount => '1000.00',
        max_order_amount => '10000.00',
    },
    'block trade order limits returned in p2p_advertiser_info'
);

$config->block_trade->enabled(0);

cmp_deeply(
    exception {
        P2P->new(client => $advertiser)->p2p_advert_create(%params);
    },
    {
        error_code => 'BlockTradeDisabled',
    },
    'Cannot create block trade ad if feature disabled'
);

$config->block_trade->enabled(1);

my $ad;
is(
    exception {
        $ad = P2P->new(client => $advertiser)->p2p_advert_create(%params);
    },
    undef,
    'Create block trade ad ok'
);

ok $ad->{block_trade},                                       'block_trade is true in p2p_advert_create response';
ok $client->p2p_advert_info(id => $ad->{id})->{block_trade}, 'block_trade is true in p2p_advert_info';
ok $advertiser->p2p_advertiser_adverts()->[0]{block_trade},  'block_trade is true in p2p_advertiser_adverts';
ok $advertiser->p2p_advert_update(
    id          => $ad->{id},
    description => 'y'
)->{block_trade}, 'block_trade is true in p2p_advert_update response';

cmp_ok $client->p2p_advert_list(block_trade => 0)->@*, '==', 0, 'ad not shown on normal ad list';
cmp_ok $client->p2p_advert_list(block_trade => 1)->@*, '==', 1, 'ad shown on block trade ad list';

$config->block_trade->enabled(0);
cmp_deeply(
    exception {
        $client->p2p_advert_list(block_trade => 1);
    },
    {
        error_code => 'BlockTradeDisabled',
    },
    'cannot view block trade ads if feature disabled'
);
$config->block_trade->enabled(1);

cmp_deeply(
    exception {
        $client->p2p_order_create(
            advert_id   => $ad->{id},
            amount      => 1000,
            rule_engine => BOM::Rules::Engine->new());
    },
    {
        error_code => 'BlockTradeNotAllowed',
    },
    'Cannot create block trade order if in wrong band'
);

$client->db->dbic->dbh->do("UPDATE p2p.p2p_advertiser SET trade_band = 'block_trade_medium' WHERE id = " . $client->p2p_advertiser_info->{id});
delete $client->{_p2p_advertiser_cached};

$config->block_trade->enabled(0);
cmp_deeply(
    exception {
        $client->p2p_order_create(
            advert_id   => $ad->{id},
            amount      => 1000,
            rule_engine => BOM::Rules::Engine->new());
    },
    {
        error_code => 'BlockTradeDisabled',
    },
    'cannot create block trade order if feature disabled'
);
$config->block_trade->enabled(1);

my $order;

is(
    exception {
        $order = $client->p2p_order_create(
            advert_id   => $ad->{id},
            amount      => 1000,
            rule_engine => BOM::Rules::Engine->new());
    },
    undef,
    'Create order ok'
);

ok $order->{advert_details}{block_trade},                                      'advert_details/block_trade is true in p2p_order_create response';
ok $client->p2p_order_info(id => $order->{id})->{advert_details}{block_trade}, 'advert_details/block_trade is true in p2p_order_info';
ok $client->p2p_order_list()->{list}[0]{advert_details}{block_trade},          'advert_details/block_trade is true in p2p_order_list';

$client->p2p_order_confirm(id => $order->{id});
$advertiser->p2p_order_confirm(id => $order->{id});

cmp_ok $advertiser->account->balance, '==', 9000, 'advertiser balance decreased';
cmp_ok $client->account->balance,     '==', 1000, 'client balance decreased';

cmp_deeply(
    exception {
        $advertiser->p2p_advert_update(
            id               => $ad->{id},
            min_order_amount => 999
        );
    },
    {
        error_code     => 'BelowPerOrderLimit',
        message_params => ['1000.00', 'USD'],
    },
    'Cannot update min order amount below band min'
);

cmp_deeply(
    exception {
        $advertiser->p2p_advert_update(
            id               => $ad->{id},
            max_order_amount => 10001
        );
    },
    {
        error_code     => 'MaxPerOrderExceeded',
        message_params => ['10000.00', 'USD'],
    },
    'Cannot update max order amount over band max'
);

cmp_deeply(
    exception {
        $advertiser->p2p_advert_update(
            id               => $ad->{id},
            remaining_amount => 19001
        );
    },
    {
        error_code     => 'MaximumExceededNewAmount',
        message_params => ['20000.00', '1000.00', '20001.00', 'USD'],
    },
    'Cannot update remaining amount to exceed max ad limit'
);

$advertiser->db->dbic->dbh->do("UPDATE p2p.p2p_advertiser SET trade_band = 'block_trade_high' WHERE id = " . $advertiser->p2p_advertiser_info->{id});
delete $advertiser->{_p2p_advertiser_cached};

is(
    exception {
        $advertiser->p2p_advert_update(
            id               => $ad->{id},
            max_order_amount => 20000
        );
    },
    undef,
    'Can increase max order after band increase'
);

$advertiser->db->dbic->dbh->do("UPDATE p2p.p2p_advertiser SET trade_band = 'low' WHERE id = " . $advertiser->p2p_advertiser_info->{id});
delete $advertiser->{_p2p_advertiser_cached};

cmp_deeply(
    $advertiser->p2p_advert_info(id => $ad->{id})->{visibility_status},
    supersetof('advertiser_block_trade_ineligible'),
    'visibility_status contains advertiser_block_trade_ineligible when advertiser is in non-block trade band'
);

done_testing();
