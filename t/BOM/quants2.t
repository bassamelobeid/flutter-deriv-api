use strict;
use warnings;

no indirect;

use Test::More;
use Test::Fatal;
use Test::MockModule;
use Test::Warnings;

use BOM::Config;
use BOM::Config::Quants;

my $redis_exchangerates = BOM::Config::Redis::redis_exchangerates_write();
# Mocking the exchange rate values with static ones in redis,
# since they will change dynamically and cause the test cases to fail.
$redis_exchangerates->set('limit:USD-to-AUD:10', 10);
$redis_exchangerates->set('limit:USD-to-AUD:45', 45);
$redis_exchangerates->set('limit:USD-to-AUD:65', 65);
$redis_exchangerates->set('limit:USD-to-AUD:95', 95);

my @all_currencies = qw(EUR ETH AUD eUSDT tUSDT BTC LTC UST USDC USD GBP);

for my $currency (@all_currencies) {
    $redis_exchangerates->hmset(
        'exchange_rates::' . $currency . '_USD',
        quote => 1,
        epoch => time
    );
}

my $config_mock  = Test::MockModule->new("BOM::Config");
my $mocked_quant = {
    commission    => {},
    default_stake => {},
    bet_limits    => {
        min_payout => {
            default_landing_company => {
                default_market => {
                    default_contract_category => {
                        USD => 10,
                        EUR => 20,
                    }
                },
            },
            maltainvest => {
                synthetic => {
                    default_contract_category => {
                        AUD => 10,
                        EUR => 20,
                    }}}
        },
        max_payout => {
            default_landing_company => {
                default_market => {
                    default_contract_category => {
                        USD => 90,
                        EUR => 30,
                    }}
            },
            maltainvest => {
                synthetic => {
                    default_contract_category => {
                        AUD => 95,
                        EUR => 20,
                    }}}
        },
        max_stake => {
            default_landing_company => {
                default_market => {
                    default_contract_category => {
                        USD => 40,
                        EUR => 50,
                    }}
            },
            maltainvest => {
                synthetic => {
                    default_contract_category => {
                        AUD => 45,
                        EUR => 20,
                    }}}
        },
        min_stake => {
            default_landing_company => {
                default_market => {
                    default_contract_category => {
                        USD => 60,
                        EUR => 70,
                    }}
            },
            maltainvest => {
                synthetic => {
                    default_contract_category => {
                        AUD => 65,
                        EUR => 20,
                    }}}}}};
$config_mock->redefine("quants" => $mocked_quant);

subtest 'minimum_payout_limit ' => sub {

    is BOM::Config::Quants::minimum_payout_limit("USD", "default_market", "default_contract_category"),
        $mocked_quant->{bet_limits}->{min_payout}->{default_landing_company}->{default_market}->{default_contract_category}->{USD},
        "default arguments are passed";
    is BOM::Config::Quants::minimum_payout_limit("AUD", "maltainvest", "synthetic", "default_contract_category"),
        $mocked_quant->{bet_limits}->{min_payout}->{maltainvest}->{synthetic}->{default_contract_category}->{AUD}, 'non-default arguments are passed';
    Test::Warnings::allow_warnings(1);
    is BOM::Config::Quants::minimum_payout_limit(),      undef, "no arguments return undef";
    is BOM::Config::Quants::minimum_payout_limit("ABS"), undef, "unsupported currency returns undef";
    Test::Warnings::allow_warnings(0);

};

subtest 'maximum_payout_limita' => sub {
    is BOM::Config::Quants::maximum_payout_limit("USD", "default_market", "default_contract_category"),
        $mocked_quant->{bet_limits}->{max_payout}->{default_landing_company}->{default_market}->{default_contract_category}->{USD},
        "correct arguments are passed";
    is BOM::Config::Quants::maximum_payout_limit("AUD", "maltainvest", "synthetic", "default_contract_category"),
        $mocked_quant->{bet_limits}->{max_payout}->{maltainvest}->{synthetic}->{default_contract_category}->{AUD}, 'non-default arguments are passed';
    Test::Warnings::allow_warnings(1);
    is BOM::Config::Quants::minimum_payout_limit(),      undef, "no arguments return undef";
    is BOM::Config::Quants::minimum_payout_limit("ABS"), undef, "unsupported currency returns undef";
    Test::Warnings::allow_warnings(0);
};

subtest 'maximum_stake_limit' => sub {
    is BOM::Config::Quants::maximum_stake_limit("USD", "default_market", "default_contract_category"),
        $mocked_quant->{bet_limits}->{max_stake}->{default_landing_company}->{default_market}->{default_contract_category}->{USD},
        "correct arguments are passed";
    is BOM::Config::Quants::maximum_stake_limit("AUD", "maltainvest", "synthetic", "default_contract_category"),
        $mocked_quant->{bet_limits}->{max_stake}->{maltainvest}->{synthetic}->{default_contract_category}->{AUD}, 'non-default arguments are passed';
    Test::Warnings::allow_warnings(1);
    is BOM::Config::Quants::maximum_stake_limit(),       undef, "no arguments return undef";
    is BOM::Config::Quants::minimum_payout_limit("ABS"), undef, "unsupported currency returns undef";
    Test::Warnings::allow_warnings(0);
};

subtest 'minimum_stake_limit' => sub {
    is BOM::Config::Quants::minimum_stake_limit("USD", "default_market", "default_contract_category"),
        $mocked_quant->{bet_limits}->{min_stake}->{default_landing_company}->{default_market}->{default_contract_category}->{USD},
        "correct arguments are passed";
    is BOM::Config::Quants::minimum_stake_limit("AUD", "maltainvest", "synthetic", "default_contract_category"),
        $mocked_quant->{bet_limits}->{min_stake}->{maltainvest}->{synthetic}->{default_contract_category}->{AUD}, 'non-default arguments are passed';
    Test::Warnings::allow_warnings(1);
    is BOM::Config::Quants::minimum_stake_limit(),       undef, "no arguments return undef";
    is BOM::Config::Quants::minimum_payout_limit("ABS"), undef, "unsupported currency returns undef";
    Test::Warnings::allow_warnings(0);
};

subtest 'market_pricing_limits' => sub {

    my $expected = {
        default_market => {
            USD => {
                max_payout => 90,
                min_stake  => 60
            }}};
    is_deeply(BOM::Config::Quants::market_pricing_limits(["USD"]), $expected, "default argument values are used");

    $expected = {
        default_market => {
            USD => {
                max_payout => 90,
                min_stake  => 60
            },
            EUR => {
                max_payout => 30,
                min_stake  => 70
            }}};
    is_deeply(BOM::Config::Quants::market_pricing_limits(["USD", "EUR"]), $expected, "multiple currencies with default arguments are used");

    $expected = {
        synthetic => {
            AUD => {
                max_payout => 95,
                min_stake  => 65
            },
            EUR => {
                max_payout => 20,
                min_stake  => 20
            }}};
    is_deeply(BOM::Config::Quants::market_pricing_limits(["AUD", "EUR"], "maltainvest", ["synthetic"]),
        $expected, "Non default lc and market are used");

    $expected = {};
    is_deeply(BOM::Config::Quants::market_pricing_limits(["ABC"]), $expected, "un-supported currencies are used");
    is_deeply(BOM::Config::Quants::market_pricing_limits(),        $expected, "no arguments are passed");
};

$config_mock->unmock_all();

done_testing;
