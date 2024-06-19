use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::MockObject;
use Commission::Helper::CTraderHelper;

my $redis_mock    = Test::MockObject->new;
my $helper        = Commission::Helper::CTraderHelper->new(redis => $redis_mock);
my $mocked_helper = Test::MockModule->new('Commission::Helper::CTraderHelper');

subtest "Test CTraderHelper.pm" => sub {

    subtest 'Test get_loginid' => sub {

        $mocked_helper->mock('get_loginid', sub { 'CTR420' });
        my $loginid = $helper->get_loginid(
            server    => 'real',
            traderIds => [1]);
        is_deeply($loginid, 'CTR420', 'get_loginid returns the correct loginid');

    };

    subtest 'Test get_underlying_symbol' => sub {

        $mocked_helper->mock('get_underlying_symbol', sub { 'AUD/JPY' });
        my $symbol = $helper->get_underlying_symbol(dealId => 69);
        is_deeply($symbol, 'AUD/JPY', 'get_underlying_symbol returns the correct symbol');

    };

    subtest 'Test get_symbolid_by_dealid' => sub {

        $mocked_helper->mock('get_symbolid_by_dealid', sub { 42069 });
        my $symbol_id = $helper->get_symbolid_by_dealid(dealId => 360);
        is_deeply($symbol_id, 42069, 'get_symbolid_by_dealid returns the correct symbol id');

    };

    subtest 'Test get_symbol_by_id' => sub {

        $mocked_helper->mock('get_symbol_by_id', sub { '{"symbol":"LTC/BTC","currency":"BTC","type":"CRYPTO"}' });
        my $symbol_json = $helper->get_symbol_by_id(symbolId => 322);
        is_deeply($symbol_json, '{"symbol":"LTC/BTC","currency":"BTC","type":"CRYPTO"}', 'get_symbol_by_id returns the correct symbol JSON');

    };

};

done_testing();
