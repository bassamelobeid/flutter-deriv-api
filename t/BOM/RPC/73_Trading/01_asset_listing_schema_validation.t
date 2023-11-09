use strict;
use warnings;
use Test::More;
use Test::MockModule;
use BOM::RPC::v3::Trading;

subtest 'trading_platform_asset_listing follows output schema' => sub {
    my $mocked_trading_platform = Test::MockModule->new('BOM::TradingPlatform::MT5');
    $mocked_trading_platform->mock(
        'get_assets',
        sub {
            [{
                    symbol                => 'EUR/USD',
                    extra_field           => 'should not exist in output',
                    bid                   => 0.01,
                    ask                   => 0.01,
                    spread                => 0.00,
                    day_percentage_change => '+0.00%',
                    display_order         => 1,
                    market                => 'financial',
                    shortcode             => 'frxEURUSD',
                }]
        });

    my $resp = BOM::RPC::v3::Trading::trading_platform_asset_listing({args => {platform => 'mt5'}});

    is(scalar($resp->{mt5}{assets}->@*), 1, 'invalid number of objects returned');

    my %asset = $resp->{mt5}{assets}->[0]->%*;
    is(scalar(keys %asset), 8, 'invalid number of fields in object returned');
    foreach (qw(symbol bid ask spread day_percentage_change display_order market shortcode)) {
        ok(defined($asset{$_}), "missing field $_ in returned object");
    }
};

done_testing;
