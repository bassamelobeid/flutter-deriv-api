use strict;
use warnings;

use Test::Most 0.22 (tests => 162);
use Test::NoWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use Date::Utility;
use Format::Util::Numbers qw( roundnear );
use BOM::Product::ContractFactory qw( produce_contract );

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );

use BOM::Market::Underlying;
use Path::Tiny;
use YAML::XS qw(LoadFile);

my $data_file       = path(__FILE__)->parent->child('config.yml');
my $config_data     = LoadFile($data_file);
my $volsurface      = $config_data->{volsurface};
my $exchange        = $config_data->{exchange};
my $currency_config = $config_data->{currency_config};
my $interest_rate   = $config_data->{currency};
my $dividend        = $config_data->{index};
my $expected_result = $config_data->{expected_result};

my $date_start   = 1398152636;
my $date_pricing = $date_start;

my $recorded_date = Date::Utility->new($date_start);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        recorded_date => $recorded_date,
        date          => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol       => $_,
        holidays     => $exchange->{$_}->{holidays},
        market_times => $exchange->{$_}->{market_times},
        date         => Date::Utility->new,
    }) for qw( LSE FSE);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency_config',
    {
        symbol   => $_,
        daycount => $currency_config->{$_}->{daycount},
        holidays => $currency_config->{$_}->{holidays},
        date     => Date::Utility->new,
    }) for qw( GBP JPY USD EUR );

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => $_,
        rates  => $interest_rate->{$_}->{rates},
        date   => Date::Utility->new,
    }) for qw( GBP JPY USD EUR JPY-USD EUR-USD GBP-USD );

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $recorded_date,
        surface       => $volsurface->{$_}{surfaces},
    }) for qw(frxUSDJPY frxEURUSD frxGBPUSD);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_moneyness',
    {
        symbol        => $_,
        recorded_date => $recorded_date,
        surface       => $volsurface->{$_}{surfaces},
    }) for qw(FTSE GDAXI);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'index',
    {
        symbol        => $_,
        date          => Date::Utility->new,
        recorded_date => $recorded_date,
        rates         => $dividend->{$_}{rates},
    }) for qw( FTSE GDAXI);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('correlation_matrix', {date => Date::Utility->new()});

foreach my $underlying ('frxUSDJPY', 'frxEURUSD', 'FTSE', 'GDAXI') {
    foreach my $bet_type ('CALL', 'NOTOUCH', 'RANGE', 'EXPIRYRANGE', 'DIGITMATCH') {
        my $expectations = $expected_result->{$underlying}->{$bet_type};
        next unless scalar keys %$expectations;

        my %barriers =
            $expectations->{barrier2}
            ? (
            high_barrier => $expectations->{barrier},
            low_barrier  => $expectations->{barrier2})
            : (barrier => $expectations->{barrier});
        my $bet_params = {
            bet_type     => $bet_type,
            date_pricing => $date_pricing,
            date_start   => $date_start,
            duration     => $expectations->{duration},
            underlying   => $underlying,
            payout       => 100,
            currency     => 'USD',
            current_spot => $expectations->{spot},
            %barriers,
        };
        my $bet;
        lives_ok { $bet = produce_contract($bet_params); } "Can create example $bet_type bet on $underlying";
        is($bet->volsurface->recorded_date->datetime_iso8601, '2014-04-22T07:43:56Z',        'We loaded the correct volsurface');
        is($bet->pricing_engine_name,                         $expectations->{price_engine}, 'Contract selected ' . $expectations->{price_engine});

        if ($bet->two_barriers) {
            is($bet->high_barrier->supplied_barrier, $expectations->{barrier}, 'Barrier is set as expected.');
            is($bet->low_barrier->supplied_barrier, $expectations->{barrier2}, ' .. and so is barrier2.') if (defined $expectations->{barrier2});
        } else {
            is($bet->barrier->supplied_barrier, $expectations->{barrier}, 'Barrier is set as expected.');
        }
        my $ask = $bet->ask_probability;
        is(roundnear(1e-4, $ask->amount), $expectations->{ask_prob}, 'Ask probability is correct.');
        my $theo = $bet->theo_probability;
        is(roundnear(1e-4, $theo->amount),                          $expectations->{theo_prob},         'Theo probability is correct.');
        is(roundnear(1e-4, $ask->peek_amount('total_markup')),      $expectations->{total_markup},      'Total markup is correct.');
        is(roundnear(1e-4, $ask->peek_amount('commission_markup')), $expectations->{commission_markup}, 'Commission markup is correct.');
        is(roundnear(1e-4, $ask->peek_amount('risk_markup')),       $expectations->{risk_markup},       'Risk markup is correct.');
    }
}

1;
