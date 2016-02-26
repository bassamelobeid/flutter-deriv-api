use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use Date::Utility;
use BOM::Test::Runtime qw(:normal);
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestMD qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis;

my $date_pricing = '8-Nov-12';

BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'currency',
    {
        symbol => $_,
        recorded_date   => Date::Utility->new($date_pricing),
    }) for (qw/GBP JPY USD JPY-USD/);

BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date   => Date::Utility->new($date_pricing),
    }) for qw( frxUSDJPY frxGBPJPY frxGBPUSD );

BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'currency',
    {
        symbol => 'JPY',
        rates  => {
            1   => 0.2,
            2   => 0.15,
            7   => 0.18,
            32  => 0.25,
            62  => 0.2,
            92  => 0.18,
            186 => 0.1,
            365 => 0.13,
        },
        type         => 'implied',
        implied_from => 'USD',
        recorded_date   => Date::Utility->new($date_pricing),
    });

BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'currency',
    {
        symbol => 'GBP',
        rates  => {
            1   => 0.2,
            2   => 0.15,
            7   => 0.18,
            32  => 0.25,
            62  => 0.2,
            92  => 0.18,
            186 => 0.1,
            365 => 0.13,
        },
        type         => 'implied',
        implied_from => 'USD',
        recorded_date   => Date::Utility->new($date_pricing),
    });

my %bet_params = (
    bet_type     => 'CALL',
    date_pricing => '8-Nov-12',
    date_start   => '8-Nov-12',
    date_expiry  => '12-Nov-12',
    underlying   => 'frxUSDJPY',
    barrier      => 77,
    barrier2     => 75,
    current_spot => 76,
    payout       => 100,
    currency     => 'GBP',
);
my $call = produce_contract({%bet_params});

subtest 'Base.' => sub {
    plan tests => 3;

    foreach my $greek_engine (qw( Greeks )) {

        my $greeks = "BOM::Product::Pricing::$greek_engine"->new(bet => $call);
        my $greeks_ref = $greeks->get_greeks;

        is(ref $greeks_ref, 'HASH', 'get_greeks returns a HashRef.');
        cmp_deeply([sort keys %{$greeks_ref}], [qw(delta gamma theta vanna vega volga)], 'get_greeks has correct keys.');

        throws_ok { $greeks->get_greek('mama') } qr/Unknown greek/, 'mama is not a greek.';
    }
};

done_testing;
