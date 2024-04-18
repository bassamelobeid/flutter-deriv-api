use strict;
use warnings;
use Test::More;
use Test::Deep;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use await;

my $t = build_wsapi_test();

subtest 'Trading platforms configuration' => sub {
    my $res = $t->await::trading_platforms({trading_platforms => 1});

    test_schema('trading_platforms', $res);

    my ($cfd, $options) = @{$res->{trading_platforms}}{qw/contract_for_difference options/};

    cmp_deeply $cfd,
        +{
        shortcode           => 'cfd',
        available_platforms => {
            mt5     => {display_name => 'Deriv MT5'},
            ctrader => {display_name => 'Deriv cTrader'},
            derivx  => {display_name => 'Deriv X'}
        },
        markets => {
            financial => {
                description => 'This account offers CFDs on financial instruments',
            },
            derived => {
                description => 'This account offers CFDs on derived instruments',
            },
        },
        products => {
            swap_free => {
                description =>
                    'Trade swap-free CFDs on MT5 with forex, stocks, stock indices, commodities, cryptocurrencies, ETFs and synthetic indices',
                display_name        => 'Swap Free',
                supported_platforms => {
                    mt5 => {
                        real => {
                            markets => {
                                financial => {},
                                derived   => {}}
                        },
                        demo => {
                            markets => {
                                derived   => {},
                                financial => {}}}}}
            },
            straight_through_processing => {
                supported_platforms => {mt5 => {real => {markets => {financial => {}}}}},
                display_name        => 'STP'
            },
            standard => {
                display_name        => 'Standard',
                supported_platforms => {
                    derivx => {
                        demo => {markets => {'all' => {}}},
                        real => {markets => {'all' => {}}}
                    },
                    mt5 => {
                        real => {
                            markets => {
                                financial => {},
                                derived   => {}}
                        },
                        demo => {
                            markets => {
                                financial => {},
                                derived   => {}}}
                    },
                    ctrader => {
                        real => {markets => {'all' => {}}},
                        demo => {markets => {'all' => {}}}}}
            },
        }
        },
        'This is the complete CFD configuration';

    cmp_deeply $options,
        +{
        shortcode           => 'options',
        available_platforms => {
            go => {
                description  => 'Trade on the go with our mobile app',
                display_name => 'Deriv Go'
            },
            binary_bot => {
                legacy       => 1,
                display_name => 'Binary Bot'
            },
            dtrader => {
                description  => 'Options trading platform',
                display_name => 'Deriv Trader'
            },
            bot => {
                display_name => 'Deriv Bot',
                description  => 'Automate your trading, no coding needed'
            },
            smart_trader => {
                legacy       => 1,
                description  => 'Our legacy options trading platform',
                display_name => 'SmartTrader'
            }
        },
        products => {
            binary => {
                display_name        => 'Binary',
                supported_platforms => {
                    dtrader      => {},
                    smart_trader => {},
                    bot          => {},
                    binary_bot   => {}}
            },
            vanilla => {
                display_name        => 'Vanilla',
                supported_platforms => {dtrader => {}}
            },
            multipliers => {
                display_name        => 'Multiplier',
                supported_platforms => {
                    dtrader => {},
                    go      => {}}
            },
            turbos => {
                display_name        => 'Turbos',
                supported_platforms => {dtrader => {}}
            },
            accumulators => {
                display_name        => 'Accumulators',
                supported_platforms => {
                    dtrader => {},
                    go      => {}}}}
        },
        'This is the complete Options configuration';
};

$t->finish_ok;

done_testing;
