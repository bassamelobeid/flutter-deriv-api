use Test::Most;
use Test::MockTime::HiRes qw(set_absolute_time);
use Date::Utility;
use Test::MockModule;
use BOM::Test::Initializations;
use BOM::Pricing::v3::MarketData;
set_absolute_time('2022-09-04T10:00:00Z');
note "set time to: " . Date::Utility->new->date . " - " . Date::Utility->new->epoch;

subtest 'set_get_cache' => sub {

    BOM::Pricing::v3::MarketData::_set_cache('testkey', 'test_value');
    my $result = BOM::Pricing::v3::MarketData::_get_cache('testkey');
    is $result , 'test_value', 'get_cache matches';
};

subtest 'trading_times' => sub {
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
                'name'       => 'Derived',
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
