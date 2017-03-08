use strict;
use warnings;

use Test::Deep qw( cmp_deeply );
use Test::More (tests => 1);
use Test::FailWarnings;
use Test::Exception;
use Test::MockModule;

use File::Spec;
use JSON qw(decode_json);
use Date::Utility;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );

use Postgres::FeedDB::Spot::Tick;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Product::ContractFactory::Parser qw(
    shortcode_to_parameters
);

subtest 'shortcode_to_parameters' => sub {
    my $frxUSDJPY = create_underlying('frxUSDJPY');

    my $legacy = shortcode_to_parameters('DOUBLEDBL_frxUSDJPY_100_10_OCT_12_I_10H10_U_11H10_D_12H10', 'USD');
    is($legacy->{bet_type}, 'Invalid', 'Legacy shortcode.');

    my $rmg_dated_call = shortcode_to_parameters('CALL_frxUSDJPY_100_10_OCT_12_17_OCT_12_S1P_S2P', 'USD');
    is($rmg_dated_call->{bet_type},    'CALL',                                           'parsed bet_type');
    is($rmg_dated_call->{date_start},  Date::Utility->new('2012-10-10')->epoch,          'parsed start time');
    is($rmg_dated_call->{date_expiry}, Date::Utility->new('2012-10-17 23:59:59')->epoch, 'parsed expiry time');

    my $call = shortcode_to_parameters('CALL_frxUSDJPY_100.00_1352351000_1352354600_S1P_S2P', 'USD');
    my $expected = {
        underlying   => $frxUSDJPY,
        high_barrier => 'S1P',
        shortcode    => 'CALL_frxUSDJPY_100.00_1352351000_1352354600_S1P_S2P',
        low_barrier  => 'S2P',
        date_expiry  => '1352354600',
        bet_type     => 'CALL',
        currency     => 'USD',
        date_start   => '1352351000',
        prediction   => undef,
        amount_type  => 'payout',
        amount       => '100.00',
        fixed_expiry => undef,
        tick_count   => undef,
        tick_expiry  => undef,
        is_sold      => undef
    };
    cmp_deeply($call, $expected, 'CALL shortcode.');

    my $put = shortcode_to_parameters('PUT_frxUSDJPY_100.00_1352351000_9_NOV_12_80_90', 'USD');
    is($put->{bet_type},    'PUT',                                            'parsed bet_type');
    is($put->{date_start},  Date::Utility->new(1352351000)->epoch,            'parsed start time');
    is($put->{date_expiry}, Date::Utility->new('2012-11-09 21:00:00')->epoch, 'parsed expiry time');

    my $tickup = shortcode_to_parameters('FLASHU_frxUSDJPY_100.00_1352351000_9T_0_0', 'USD');
    $expected = {
        underlying   => $frxUSDJPY,
        barrier      => '0',
        shortcode    => 'FLASHU_frxUSDJPY_100.00_1352351000_9T_0_0',
        date_expiry  => undef,
        bet_type     => 'FLASHU',
        currency     => 'USD',
        date_start   => '1352351000',
        prediction   => undef,
        amount_type  => 'payout',
        amount       => '100.00',
        fixed_expiry => undef,
        tick_count   => 9,
        tick_expiry  => 1,
        is_sold      => undef
    };
    cmp_deeply($tickup, $expected, 'FLASH tick expiry shortcode.');

    $call = shortcode_to_parameters('CALL_frxUSDJPY_100.00_1352351000_1352354600_S1P_S2P', 'USD', 1);
    $expected = {
        underlying   => $frxUSDJPY,
        high_barrier => 'S1P',
        shortcode    => 'CALL_frxUSDJPY_100.00_1352351000_1352354600_S1P_S2P',
        low_barrier  => 'S2P',
        date_expiry  => '1352354600',
        bet_type     => 'CALL',
        currency     => 'USD',
        date_start   => '1352351000',
        prediction   => undef,
        amount_type  => 'payout',
        amount       => '100.00',
        fixed_expiry => undef,
        tick_count   => undef,
        tick_expiry  => undef,
        is_sold      => 1
    };
    cmp_deeply($call, $expected, 'CALL shortcode. for is_sold');
};

1;
