use strict;
use warnings;

use Test::Deep qw( cmp_deeply );
use Test::More (tests => 2);
use Test::FailWarnings;
use Test::Exception;
use Test::MockModule;

use File::Spec;
use JSON qw(decode_json);
use Date::Utility;
use BOM::Market::Underlying;
use BOM::Test::Data::Utility::UnitTestMD qw( :init );
use BOM::Test::Data::Utility::UnitTestDatabase qw( :init );

use BOM::Market::Data::Tick;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Product::ContractFactory::Parser qw(
    shortcode_to_parameters
    financial_market_bet_to_parameters
);

subtest 'financial_market_bet_to_parameters' => sub {
    plan tests => 11;

    throws_ok {
        financial_market_bet_to_parameters('NotAFMBInstance.', 'USD');
    }
    qr/Expected BOM::Database::Model::FinancialMarketBet instance/;

    my $fmb = BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
        type    => 'fmb_range_bet',
        buy_bet => 0,
    });

    my $params = financial_market_bet_to_parameters($fmb, 'USD');
    is($params->{bet_type}, 'RANGE', 'RangeBet is a RANGE.');

    $fmb = BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
        type    => 'fmb_touch_bet_buy',
        buy_bet => 0,
    });
    $params = financial_market_bet_to_parameters($fmb, 'USD');
    is($params->{bet_type}, 'ONETOUCH', 'TouchBet is a ONETOUCH.');
    is($params->{is_sold},  0,          'Have correct is_sold param');

    my $tick_expiry_fmb = BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
        type       => 'fmb_higher_lower',
        buy_bet    => 0,
        tick_count => 5,
    });
    my $new_params = financial_market_bet_to_parameters($tick_expiry_fmb, 'USD');
    ok($new_params->{tick_expiry}, 'is a tick expiry contract');
    is($new_params->{tick_count}, 5, 'tick count is 5');

    my $spread_bet_fmb = BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({type => 'fmb_spread_bet'});
    my $spread_params = financial_market_bet_to_parameters($spread_bet_fmb, 'USD');
    is $spread_params->{stop_type},        'point', 'stop type';
    is $spread_params->{stop_loss},        10,      'stop_loss is 10';
    is $spread_params->{stop_profit},      10,      'stop_profit is 10';
    is $spread_params->{amount_per_point}, 1,       'amount_per_point 1';
    is $spread_params->{spread},           1,       'spread is 1';
};

subtest 'shortcode_to_parameters' => sub {
    plan tests => 6;

    my $frxUSDJPY = BOM::Market::Underlying->new('frxUSDJPY');

    my $legacy = shortcode_to_parameters('DOUBLEDBL_frxUSDJPY_100_10_OCT_12_I_10H10_U_11H10_D_12H10', 'USD');
    is($legacy->{bet_type}, 'Invalid', 'Legacy shortcode.');

    my $rmg_dated_call = shortcode_to_parameters('CALL_frxUSDJPY_100_10_OCT_12_17_OCT_12_S1P_S2P', 'USD');
    is($rmg_dated_call->{bet_type}, 'Invalid', 'RMG dated CALL shortcode is marked as legacy');

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
    is($put->{bet_type}, 'Invalid', 'Invalid bet_type for RMG-dated PUT shortcode.');

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
