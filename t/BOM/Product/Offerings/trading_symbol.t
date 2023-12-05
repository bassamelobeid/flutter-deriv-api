#!/usr/bin/perl

use strict;
use warnings;

use Test::Deep;
use Test::More;
use Test::Fatal;
use Test::Exception;
use Test::FailWarnings;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use Quant::Framework::Underlying;
use BOM::Product::Offerings::TradingSymbol qw(get_symbols _filter_no_business_profiles);
use Brands;
use LandingCompany::Offerings;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;

# since it's trading symbols, it's easier to mock the method rather
# than creating all the ticks for each symbol
my $mocked_u = Test::MockModule->new('Quant::Framework::Underlying');
$mocked_u->mock('spot',      sub { return 100 });
$mocked_u->mock('spot_time', sub { return time });
$mocked_u->mock('spot_age',  sub { return 1 });

# we want to test the behaviour of non-asian hours first!
my $mocked_o = Test::MockModule->new('LandingCompany::Offerings');
$mocked_o->mock('is_asian_hours', sub { return 1 });

subtest 'error check' => sub {
    lives_ok {
        my $res = get_symbols();
        ok !$res->{error},  'no error';
        ok $res->{symbols}, 'returns symbol list';
        is $res->{symbols}->@*, 90, '90 active symbols';
    }
    'throws an error when landing company is not provided';

    my $error = exception { get_symbols({landing_company_name => 'invalid'}) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Landing company is invalid.', 'landing company is invalid';

    lives_ok {
        my $res = get_symbols({
            landing_company_name => 'svg',
            country_code         => 'xx'
        });
        ok !$res->{error},  'no error';
        ok $res->{symbols}, 'returns symbol list';
        is $res->{symbols}->@*, 84, '84 active symbols';
    }
    'invalid country_code will not throw an error';

    lives_ok {
        my $res = get_symbols({
            landing_company_name => 'svg',
            country_code         => 'id',
            app_id               => 123
        });
        ok !$res->{error},  'no error';
        ok $res->{symbols}, 'returns symbol list';
        is $res->{symbols}->@*, 84, '84 active symbols';
    }
    'invalid app_id will not throw an error';

    lives_ok {
        my $res = get_symbols({
            contract_type        => ["RANGE"],
            app_id               => 1004,
            landing_company_name => undef,
            country_code         => 'my'
        });

        # Remove "OTC_IBEX35" and "frxEURCAD" members from the $res->{symbols} array
        # The reason for removing these two members is that the active_symbols list,
        # when applied with the contract_type 'RANGE,' contains two additional members
        # in the testing environment compared to the QA environment.

        @{$res->{symbols}} = grep { $_->{symbol} ne "OTC_IBEX35" && $_->{symbol} ne "frxEURCAD" } @{$res->{symbols}};

        ok !$res->{error},  'no error';
        ok $res->{symbols}, 'returns symbol list';
        is $res->{symbols}->@*, 39, '39 active symbols';
    }
    'invalid RANGE will not throw an error';

    lives_ok {
        my $res = get_symbols({
            contract_type        => ["ASIANU"],
            app_id               => 1004,
            landing_company_name => undef,
            country_code         => 'my'
        });

        ok !$res->{error},  'no error';
        ok $res->{symbols}, 'returns symbol list';
        is $res->{symbols}->@*, 10, '10 active symbols';
    }
    'invalid ASIANU will not throw an error';

    lives_ok {
        my $res = get_symbols({
            contract_type        => ["RANGE", "ASIANU"],
            app_id               => 1004,
            landing_company_name => undef,
            country_code         => 'my'
        });

        @{$res->{symbols}} = grep { $_->{symbol} ne "OTC_IBEX35" && $_->{symbol} ne "frxEURCAD" } @{$res->{symbols}};

        ok !$res->{error},  'no error';
        ok $res->{symbols}, 'returns symbol list';
        is $res->{symbols}->@*, 39, '39 active symbols';
    }
    'invalid Union of RANGE, ASIANU will not throw an error';
};

subtest 'with invalid app id - 123' => sub {
    subtest 'landing company - virtual' => sub {
        # We should have a list of countries in product offerings service
        # rather depending on Brands::Countries.
        # This should be changed when we move BOM::Product::Offerings::* to its service.
        my $countries    = Brands->new->countries_instance->countries_list;
        my $lc           = 'virtual';
        my $app_id       = 123;                                               # this will go to default app id offerings
        my %special_case = (
            'at' => 30,
            'au' => 19,
            'be' => 0,
            'bg' => 30,
            'cn' => 84,
            'cy' => 30,
            'cz' => 30,
            'de' => 30,
            'dk' => 30,
            'ee' => 30,
            'es' => 30,
            'fi' => 30,
            'fr' => 30,
            'gb' => 14,
            'gr' => 30,
            'hr' => 30,
            'hu' => 30,
            'ie' => 30,
            'im' => 0,
            'it' => 30,
            'jp' => 22,
            'lt' => 30,
            'lu' => 30,
            'lv' => 30,
            'nl' => 30,
            'no' => 22,
            'pl' => 30,
            'pt' => 30,
            'ro' => 30,
            'se' => 30,
            'sg' => 52,
            'si' => 30,
            'sk' => 30,
            'tw' => 84,
        );
        foreach my $code (keys $countries->%*) {
            my $res = get_symbols({
                landing_company_name => $lc,
                app_id               => $app_id,
                country_code         => $code,
            });
            my $expected = $special_case{$code} // 90;
            ok $res->{symbols}->@* == $expected, " correct active symbols for $code, got " . scalar($res->{symbols}->@*) . " expected $expected";
        }
    };

    subtest 'landing company - svg' => sub {
        my $countries    = Brands->new->countries_instance->countries_list;
        my $lc           = 'svg';
        my $app_id       = 123;                                               # this will go to default app id offerings
        my %special_case = (
            'au' => 19,
            'jp' => 22,
            'no' => 22,
            'sg' => 52,
        );
        foreach my $code (keys $countries->%*) {
            if ($countries->{$code}{gaming_company} eq $lc or $countries->{$code}{financial_company} eq $lc) {
                my $res = get_symbols({
                    landing_company_name => $lc,
                    app_id               => $app_id,
                    country_code         => $code,
                });
                my $expected = $special_case{$code} // 84;
                ok $res->{symbols}->@* == $expected, " correct active symbols for $code, got " . scalar($res->{symbols}->@*) . " expected $expected";
            }
        }
    };

    subtest 'landing company - maltainvest' => sub {
        my $countries    = Brands->new->countries_instance->countries_list;
        my $lc           = 'maltainvest';
        my $app_id       = 123;                                               # this will go to default app id offerings
        my %special_case = (gb => 14);
        foreach my $code (keys $countries->%*) {
            if ($countries->{$code}{gaming_company} eq $lc or $countries->{$code}{financial_company} eq $lc) {
                my $res = get_symbols({
                    landing_company_name => $lc,
                    app_id               => $app_id,
                    country_code         => $code,
                });
                my $expected = $special_case{$code} // 30;
                ok $res->{symbols}->@* == $expected, " correct active symbols for $code, got " . scalar($res->{symbols}->@*) . " expected $expected";
            }
        }
    };
};

subtest 'trading symbol by app id' => sub {
    subtest 'deriv' => sub {
        my $deriv                 = Brands->new(name => 'deriv');
        my %expected_symbol_count = (
            30767 => 85,
            30768 => 69,
            11780 => 85,
            1408  => 0,
            16303 => 85,
            16929 => 85,
            19111 => 80,
            19112 => 80,
            22168 => 69,
            23789 => 88,
            29864 => 69,
            1411  => 85,
            27315 => 69,
            31254 => 0,
            29808 => 0,
            46333 => 0,
            46123 => 0,
        );
        my $app = $deriv->whitelist_apps;
        foreach my $app_id (keys %$app) {
            my $res = get_symbols({
                app_id => $app_id,
                brands => $deriv,
            });
            if (exists $expected_symbol_count{$app_id}) {
                is scalar $res->{symbols}->@*, $expected_symbol_count{$app_id},
                    'symbol count expected for ' . $app->{$app_id}{name} . ' with id ' . $app_id;
            } else {
                fail('symbol count not defined for ' . $app->{$app_id}{name} . ' with id ' . $app_id);
            }
        }
    };

    subtest 'binary' => sub {
        my $binary                = Brands->new(name => 'binary');
        my %expected_symbol_count = (
            1     => 64,
            1098  => 64,
            10    => 17,
            11    => 64,
            1086  => 64,
            1169  => 64,
            14473 => 64,
            15284 => 64,
            15437 => 64,
            15438 => 64,
            15481 => 64,
            15488 => 17,
            29808 => 0,
            31254 => 0,
            46333 => 0,
            46123 => 0,
        );
        my $app = $binary->whitelist_apps;
        foreach my $app_id (keys %$app) {
            my $res = get_symbols({
                app_id => $app_id,
                brands => $binary,
            });
            if (exists $expected_symbol_count{$app_id}) {
                is scalar $res->{symbols}->@*, $expected_symbol_count{$app_id},
                    'symbol count expected for ' . $app->{$app_id}{name} . ' with id ' . $app_id;
            } else {
                fail('symbol count not defined for ' . $app->{$app_id}{name} . ' with id ' . $app_id);
            }
        }
    };
};

subtest 'suspend trading' => sub {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my $prev            = $app_config->quants->markets->suspend_buy;
    my $disabled_market = 'forex';
    $app_config->set({'quants.markets.suspend_buy' => [$disabled_market]});
    my $res = get_symbols();
    ok((!grep { $_->{market} eq $disabled_market } $res->{symbols}->@*), "$disabled_market does not show up in trading symbols");
    $app_config->set({'quants.markets.suspend_buy' => $prev});

    $prev = $app_config->quants->underlyings->suspend_buy;
    my $disabled_underlying = 'frxUSDJPY';
    $app_config->set({'quants.underlyings.suspend_buy' => [$disabled_underlying]});
    $res = get_symbols();
    ok((!grep { $_->{symbol} eq $disabled_underlying } $res->{symbols}->@*), "$disabled_underlying does not show up in trading symbols");
    $app_config->set({'quants.underlyings.suspend_buy' => $prev});
};

subtest 'type=brief' => sub {
    # default type=full
    my $res           = get_symbols({type => 'brief'});
    my $expected_keys = [
        qw(market submarket submarket_display_name pip symbol symbol_type market_display_name exchange_is_open display_name  is_trading_suspended allow_forward_starting subgroup subgroup_display_name display_order)
    ];
    cmp_bag([keys $res->{symbols}->[0]->%*], $expected_keys, 'brief symbol returns correct information');
};

subtest 'filter no business profiles' => sub {
    my $landing_company = 'svg';

    my $custom_product_profiles = {
        "contract1" => {
            "risk_profile"      => "no_business",
            "landing_company"   => "svg",
            "expiry_type"       => "",
            "start_time"        => "",
            "market"            => "forex",
            "submarket"         => "forex_basket",
            "underlying_symbol" => "frxUSDJPY",
            "contract_category" => ""
        },
        "contract2" => {
            "risk_profile"      => "no_business",
            "landing_company"   => "maltainvest",
            "expiry_type"       => "",
            "start_time"        => "",
            "market"            => "synthetic_index",
            "submarket"         => "",
            "underlying_symbol" => "",
            "contract_category" => ""
        },
        "contract3" => {
            "risk_profile"      => "no_business",
            "landing_company"   => "svg",
            "expiry_type"       => "",
            "start_time"        => "",
            "market"            => "",
            "submarket"         => "forex_basket",
            "underlying_symbol" => "CRASH300N",
            "contract_category" => ""
        }};

    my %expected_result = (
        'frxUSDJPY' => 1,
        'CRASH300N' => 1
    );

    my %actual_result = _filter_no_business_profiles($landing_company, $custom_product_profiles);
    is_deeply(\%actual_result, \%expected_result, "Checking _filter_no_business_profiles");
};

done_testing();
