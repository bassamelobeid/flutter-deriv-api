use strict;
use warnings;

use Test::More (tests => 4);
use Test::NoWarnings;
use Test::Exception;

use BOM::Test::Runtime qw(:normal);
use Date::Utility;
use BOM::Market::Currency;
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use BOM::Platform::Runtime;
use BOM::Platform::Static::Config;

my $historical_ir_date = Date::Utility->new;
#Here currency means create an "InterestRate" data item in Chronicle
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'USD',
        rates  => {
            1 => 0.2,
            7 => 0.9
        },
        date => $historical_ir_date,
    });
#wait for two seconds so the next version of this interest rate will have a different timestamp
sleep 2;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'RUR',
        recorded_date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'USD',
        rates  => {
            1 => 0.1,
            7 => 0.7
        },
        recorded_date => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'USD-JPY',
        rates  => {
            1 => 0.2,
            7 => 0.8
        },
        recorded_date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'holiday',
    {
        recorded_date => Date::Utility->new,
        calendar      => {
            "2012-01-01" => {
                "NY" => ['RUR'],
            },
            "2012-01-02" => {
                "NY 2" => ['RUR'],
            },
            "2012-01-03" => {
                "pseudo-holiday" => ['RUR'],
            },
            "2012-01-07" => {
                "Orthodox Chirstmas" => ['RUR'],
            },
        },
    });

subtest Holidays => sub {
    plan tests => 8;

    my $rur;
    lives_ok {
        $rur = BOM::Market::Currency->new('RUR');
    }
    'create RUR';

    is(scalar(keys %{$rur->holidays}), 6, '6 RUR holidays');
    my @real_holidays = grep { $rur->has_holiday_on(Date::Utility->new($_ * 86400)) } keys(%{$rur->holidays});
    is(scalar @real_holidays, 3, '3 real RUR holidays');
    ok($rur->has_holiday_on(Date::Utility->new('2012-01-01')),  'RUR has a holiday on 2012-01-01');
    ok(!$rur->has_holiday_on(Date::Utility->new('2011-12-01')), 'RUR is open on 2011-12-01');

    is($rur->weight_on(Date::Utility->new('2012-01-03')), 0.5, 'slow day');
    is($rur->weight_on(Date::Utility->new('2012-01-04')), 1.0, 'normal day');
    is($rur->weight_on(Date::Utility->new('2012-01-01')), 0.0, 'holiday');
};

subtest interest => sub {
    plan tests => 8;

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

    lives_ok { $usd = BOM::Market::Currency->new({symbol => 'USD', for_date => $historical_ir_date}) } 'creates currency object';
    can_ok($usd, 'interest');
    is_deeply(
        $usd->interest->rates,
        {
            1 => 0.2,
            7 => 0.9
        },
        'historical market_rates returns hashref of rates for a currency'
    );
    is($usd->rate_for(1 / 365), 0.002, '->rate_for($tiy) returns rates for requested term in historical mode');

};

subtest implied_rates_from => sub {
    plan tests => 5;

    BOM::Platform::Static::Config::quants->{market_data}->{interest_rates_source} = 'implied';
    is(BOM::Platform::Static::Config::quants->{market_data}->{interest_rates_source}, 'implied', 'sets environment for test');
    my $usd;
    lives_ok { $usd = BOM::Market::Currency->new('USD') } 'creates currency object';
    can_ok($usd, 'rate_implied_from');
    is($usd->rate_implied_from('JPY', 7 / 365), 0.008, '->rate_implied_from(\'JPY\', $tiy) returns rate for requested term for USD-JPY');
    BOM::Platform::Static::Config::quants->{market_data}->{interest_rates_source} = 'market';
    is(BOM::Platform::Static::Config::quants->{market_data}->{interest_rates_source}, 'market', 'resets environment after test');
};
