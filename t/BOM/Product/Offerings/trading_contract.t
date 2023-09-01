#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Fatal;
use Test::FailWarnings;
use Test::Deep;

use Brands;
use BOM::Product::Offerings::TradingContract qw(get_contracts get_offerings_obj virtual_offering_based_on_country_code);
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use Brands;

subtest 'general' => sub {
    my $error = exception { get_contracts };
    ok $error->isa('BOM::Product::Exception'), 'error is thrown';
    is $error->error_code, 'OfferingsSymbolRequired', 'error code - OfferingsSymbolRequired';

    $error = exception { get_contracts({symbol => 'R_100', landing_company_name => 'XZY'}) };
    ok $error->isa('BOM::Product::Exception'), 'error is thrown';
    is $error->error_code, 'OfferingsInvalidLandingCompany', 'error code - OfferingsInvalidLandingCompany';

    $error = exception { get_contracts({symbol => 'XZY', landing_company_name => 'svg'}) };
    ok $error->isa('BOM::Product::Exception'), 'error is thrown';
    is $error->error_code, 'OfferingsInvalidSymbol', 'error code - OfferingsInvalidSymbol';

};

subtest 'by landing company' => sub {
    my $args = {
        symbol               => 'R_100',
        landing_company_name => 'virtual',
    };
    subtest 'virtual' => sub {
        my %expected = (
            'asian'         => 2,
            'callput'       => 14,
            'callputequal'  => 8,
            'digits'        => 6,
            'endsinout'     => 4,
            'highlowticks'  => 2,
            'lookback'      => 3,
            'multiplier'    => 2,
            'reset'         => 4,
            'runs'          => 2,
            'staysinout'    => 4,
            'touchnotouch'  => 6,
            'callputspread' => 4,
            'accumulator'   => 1,
            'vanilla'       => 8,
        );
        lives_ok {
            my $contracts = get_contracts($args);
            my %count;
            my %got = map { $_->{contract_category} => ++$count{$_->{contract_category}} } $contracts->@*;
            is_deeply(\%got, \%expected, 'contracts received for virtual matched');
        }
        'can get contracts for virtual';
    };

    subtest 'svg' => sub {
        $args->{landing_company_name} = 'svg';
        my %expected = (
            'asian'         => 2,
            'callput'       => 14,
            'callputequal'  => 8,
            'digits'        => 6,
            'endsinout'     => 4,
            'highlowticks'  => 2,
            'lookback'      => 3,
            'multiplier'    => 2,
            'reset'         => 4,
            'runs'          => 2,
            'staysinout'    => 4,
            'touchnotouch'  => 6,
            'callputspread' => 4,
            'vanilla'       => 8
        );
        lives_ok {
            my $contracts = get_contracts($args);
            my %count;
            my %got = map { $_->{contract_category} => ++$count{$_->{contract_category}} } $contracts->@*;
            is_deeply(\%got, \%expected, 'contracts received for svg matched');
        }
        'can get contracts fpr svg';
    };

    subtest 'maltainvest' => sub {
        $args->{landing_company_name} = 'maltainvest';
        my $error = exception { get_contracts($args) };
        ok $error->isa('BOM::Product::Exception'), 'error is thrown';
        is $error->error_code, 'OfferingsInvalidSymbol', 'error code - OfferingsInvalidSymbol because maltainvest has no volatility indices';

        my %expected = (
            'multiplier' => 1,
        );
        lives_ok {
            $args->{symbol} = '1HZ200V';
            my $contracts = get_contracts($args);
            my %count;
            my %got = map { $_->{contract_category} => $count{$_->{contract_category}}++ } $contracts->@*;
            is_deeply(\%got, \%expected, 'contracts received for maltainvest matched');
        }
        'can get contracts fpr maltainvest';
    };
};

subtest 'by app id' => sub {
    # with virtual landing company
    subtest 'deriv' => sub {
        my $deriv = Brands->new(name => 'deriv');
        my $args  = {
            symbol => '1HZ100V',
            brands => $deriv,
        };

        my %expected = (
            11780 => 45,
            1411  => 45,
            16303 => 45,
            16929 => 45,
            19111 => 54,
            19112 => 54,
            22168 => 55,
            23789 => 28,
            27315 => 55,
            29864 => 52,
            30767 => 45,
            30768 => 55
        );
        my $apps = $deriv->whitelist_apps;
        foreach my $app_id (keys $apps->%*) {
            next
                if $apps->{$app_id}->offerings eq 'none'
                or $apps->{$app_id}->offerings eq 'mt5'
                or $apps->{$app_id}->offerings eq 'derivez'
                or $apps->{$app_id}->offerings eq 'ctrader';

            $args->{app_id} = $app_id;
            my $contracts = get_contracts($args);
            is scalar($contracts->@*), $expected{$app_id}, "contracts for $app_id matched";
        }
    };
    subtest 'binary' => sub {
        my $binary = Brands->new(name => 'binary');
        my $args   = {
            symbol => '1HZ100V',
            brands => $binary,
        };

        my %expected = (
            1     => 55,
            10    => 14,
            1086  => 47,
            1098  => 55,
            11    => 47,
            1169  => 52,
            14473 => 55,
            15284 => 55,
            15437 => 47,
            15438 => 52,
            15481 => 52,
            15488 => 14,
        );
        my $apps = $binary->whitelist_apps;
        foreach my $app_id (keys $apps->%*) {
            next
                if $apps->{$app_id}->offerings eq 'none'
                or $apps->{$app_id}->offerings eq 'mt5'
                or $apps->{$app_id}->offerings eq 'derivez'
                or $apps->{$app_id}->offerings eq 'ctrader';

            $args->{app_id} = $app_id;
            my $contracts = get_contracts($args);
            is scalar($contracts->@*), $expected{$app_id}, "contracts for $app_id matched";
        }
    };
};

subtest 'suspend trading' => sub {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my $prev            = $app_config->quants->markets->suspend_buy;
    my $disabled_market = 'forex';
    $app_config->set({'quants.markets.suspend_buy' => [$disabled_market]});
    my $res = exception { get_contracts({symbol => 'frxUSDJPY'}) };
    $res->isa('BOM::Product::Exception');
    is $res->error_code, 'OfferingsInvalidSymbol';
    $app_config->set({'quants.markets.suspend_buy' => $prev});

};

subtest 'virtual contracts based on country code' => sub {
    my $args = {
        app_id               => 16303,
        brands               => Brands->new(),
        landing_company_name => "virtual",
        country_code         => "es",
    };

    my %expected = (
        "multiplier" => 1,
    );

    my $offerings_obj           = get_offerings_obj($args);
    my %legal_allowed_contracts = virtual_offering_based_on_country_code($offerings_obj);

    is_deeply(\%legal_allowed_contracts, \%expected, "virtual contracts based on country code matched");
};

done_testing();
