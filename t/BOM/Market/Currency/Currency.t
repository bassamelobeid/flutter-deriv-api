use strict;
use warnings;

use Test::More (tests => 4);
use Test::NoWarnings;
use Test::Exception;

use BOM::Test::Runtime qw(:normal);
use Date::Utility;
use BOM::Market::Currency;
use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );
use BOM::Platform::Runtime;

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => 'RUR',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => 'USD',
        rates  => {
            1 => 0.1,
            7 => 0.7
        },
        date => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => 'USD-JPY',
        rates  => {
            1 => 0.2,
            7 => 0.8
        },
        date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency_config',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for qw( JPY USD );

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency_config',
    {
        symbol                 => 'RUR',
        bloomberg_country_code => 'RU',
        holidays               => {
            "2012-01-01" => "NY",
            "2012-01-02" => "NY 2",
            "2012-01-03" => "0.4",
            "2012-01-07" => "Orthodox Chirstmas",
        },
        date => Date::Utility->new,
    });

subtest Holidays => sub {
    plan tests => 8;

    my $rur;
    lives_ok {
        $rur = BOM::Market::Currency->new('RUR');
    }
    'create RUR';

    is(scalar(keys %{$rur->holidays}), 4, '4 RUR holidays');
    my @real_holidays = grep { $rur->has_holiday_on(Date::Utility->new($_ * 86400)) } keys(%{$rur->holidays});
    is(scalar @real_holidays, 3, '3 real RUR holidays');
    ok($rur->has_holiday_on(Date::Utility->new('2012-01-01')),  'RUR has a holiday on 2012-01-01');
    ok(!$rur->has_holiday_on(Date::Utility->new('2011-12-01')), 'RUR is open on 2011-12-01');

    is($rur->weight_on(Date::Utility->new('2012-01-03')), 0.4, 'slow day');
    is($rur->weight_on(Date::Utility->new('2012-01-04')), 1.0, 'normal day');
    is($rur->weight_on(Date::Utility->new('2012-01-01')), 0.0, 'holiday');
};

subtest interest => sub {
    plan tests => 4;

    my $usd;
    lives_ok { $usd = BOM::Market::Currency->new('USD') } 'creates currency object';
    can_ok($usd, 'interest');
    is_deeply(
        $usd->interest->rates,
        {
            1 => 0.1,
            7 => 0.7
        },
        'market_rates returns hashref of rates for a currency'
    );
    is($usd->rate_for(1 / 365), 0.001, '->rate_for($tiy) returns rates for requested term');
};

subtest implied_rates_from => sub {
    plan tests => 5;

    BOM::Platform::Runtime->instance->app_config->quants->market_data->interest_rates_source('implied');
    is(BOM::Platform::Runtime->instance->app_config->quants->market_data->interest_rates_source, 'implied', 'sets environment for test');
    my $usd;
    lives_ok { $usd = BOM::Market::Currency->new('USD') } 'creates currency object';
    can_ok($usd, 'rate_implied_from');
    is($usd->rate_implied_from('JPY', 7 / 365), 0.008, '->rate_implied_from(\'JPY\', $tiy) returns rate for requested term for USD-JPY');
    BOM::Platform::Runtime->instance->app_config->quants->market_data->interest_rates_source('market');
    is(BOM::Platform::Runtime->instance->app_config->quants->market_data->interest_rates_source, 'market', 'resets environment after test');
};
