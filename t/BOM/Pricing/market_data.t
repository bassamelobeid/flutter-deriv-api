use Test::Most;
use Test::MockTime::HiRes qw(set_absolute_time);
use Date::Utility;
use Test::MockModule;
use BOM::Pricing::v3::MarketData;

subtest 'set_get_cache' => sub {

    BOM::Pricing::v3::MarketData::_set_cache('testkey', 'test_value');
    my $result = BOM::Pricing::v3::MarketData::_get_cache('testkey');
    is $result , 'test_value', 'get_cache matches';
};

subtest '_get_digest' => sub {
    my $result = BOM::Pricing::v3::MarketData::_get_digest();
    my $expected =
        '[action-buy;loaded_revision-1664176895;suspend_contract_types-;suspend_markets-sectors;suspend_trading-0;suspend_underlying_symbols-;trading_calendar_revision-0;]';
    is $result , $expected, '_get_digest matches';
};

subtest 'trading_times' => sub {
    note "set time to: " . Date::Utility->new->date . " - " . Date::Utility->new->epoch;
    _get_cache set_absolute_time('2022-09-04T10:00:00Z');
    note "set time to: " . Date::Utility->new->date . " - " . Date::Utility->new->epoch;

    my $params->{args}->{trading_times} = 'today';
    my $result = BOM::Pricing::v3::MarketData::trading_times($params);

    my $expected = {
        'markets' => [{
                'submarkets' => ignore(),
                'name'       => 'Forex'
            },
            {
                'submarkets' => ignore(),
                'name'       => 'Stock Indices'
            },
            {
                'name'       => 'Commodities',
                'submarkets' => ignore(),
            },
            {
                'name'       => 'Synthetic Indices',
                'submarkets' => ignore(),
            },
            {
                'name'       => 'Basket Indices',
                'submarkets' => ignore(),
            },
            {
                'submarkets' => ignore(),
                'name'       => 'Cryptocurrencies'
            }]};
    cmp_deeply($result, $expected, 'Workday markets data matches');

    # test Sunday
    $params->{args}->{trading_times} = '2022-09-02T10:00:00Z';
    $result = BOM::Pricing::v3::MarketData::trading_times($params);
    cmp_deeply($result, $expected, 'Sunday markets data matches');

    $expected = {
        'events' => [{
                'descrip' => 'Closes early (at 20:55)',
                'dates'   => 'Fridays'
            }
        ],
        'symbol' => 'frxAUDJPY',
        'times'  => {
            'close'      => ['20:55:00'],
            'settlement' => '23:59:59',
            'open'       => ['00:00:00']
        },
        'name'         => 'AUD/JPY',
        'trading_days' => ['Mon', 'Tue', 'Wed', 'Thu', 'Fri']};

    cmp_deeply($result->{markets}[0]{submarkets}[0]{symbols}[0], $expected, 'Sunday Closes early');
};

done_testing;
