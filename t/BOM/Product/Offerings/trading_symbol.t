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
use BOM::Product::Offerings::TradingSymbol qw(get_symbols);
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
        is $res->{symbols}->@*, 88, '88 active symbols';
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
        is $res->{symbols}->@*, 86, '86 active symbols';
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
        is $res->{symbols}->@*, 86, '86 active symbols';
    }
    'invalid app_id will not throw an error';
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
            'at' => 28,
            'au' => 19,
            'be' => 0,
            'bg' => 28,
            'cn' => 86,
            'cy' => 28,
            'cz' => 28,
            'de' => 28,
            'dk' => 28,
            'ee' => 28,
            'es' => 28,
            'fi' => 28,
            'fr' => 28,
            'gb' => 14,
            'gr' => 28,
            'hr' => 28,
            'hu' => 28,
            'ie' => 28,
            'im' => 0,
            'it' => 28,
            'jp' => 24,
            'lt' => 28,
            'lu' => 28,
            'lv' => 28,
            'nl' => 28,
            'no' => 24,
            'pl' => 28,
            'pt' => 28,
            'ro' => 28,
            'se' => 28,
            'sg' => 52,
            'si' => 28,
            'sk' => 28,
            'tw' => 86,
        );
        foreach my $code (keys $countries->%*) {
            my $res = get_symbols({
                landing_company_name => $lc,
                app_id               => $app_id,
                country_code         => $code,
            });
            my $expected = $special_case{$code} // 88;
            ok $res->{symbols}->@* == $expected, " correct active symbols for $code, got " . scalar($res->{symbols}->@*) . " expected $expected";
        }
    };

    subtest 'landing company - svg' => sub {
        my $countries    = Brands->new->countries_instance->countries_list;
        my $lc           = 'svg';
        my $app_id       = 123;                                               # this will go to default app id offerings
        my %special_case = (
            'au' => 19,
            'jp' => 24,
            'no' => 24,
            'sg' => 52,
        );
        foreach my $code (keys $countries->%*) {
            if ($countries->{$code}{gaming_company} eq $lc or $countries->{$code}{financial_company} eq $lc) {
                my $res = get_symbols({
                    landing_company_name => $lc,
                    app_id               => $app_id,
                    country_code         => $code,
                });
                my $expected = $special_case{$code} // 86;
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
                my $expected = $special_case{$code} // 28;
                ok $res->{symbols}->@* == $expected, " correct active symbols for $code, got " . scalar($res->{symbols}->@*) . " expected $expected";
            }
        }
    };
};

subtest 'trading symbol by app id' => sub {
    subtest 'deriv' => sub {
        my $deriv                 = Brands->new(name => 'deriv');
        my %expected_symbol_count = (
            30767 => 83,
            30768 => 69,
            11780 => 83,
            1408  => 0,
            16303 => 83,
            16929 => 83,
            19111 => 78,
            19112 => 78,
            22168 => 69,
            23789 => 49,
            29864 => 69,
            1411  => 83,
            27315 => 69,
            31254 => 0,
            29808 => 0,

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

done_testing();
