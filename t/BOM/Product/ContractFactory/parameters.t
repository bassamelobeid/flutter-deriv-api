use strict;
use warnings;

use Test::Deep qw( cmp_deeply );
use Test::More (tests => 2);
use Test::Warnings;
use Test::Exception;
use Test::MockModule;

use File::Spec;
use Date::Utility;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );

use Postgres::FeedDB::Spot::Tick;
use BOM::Product::ContractFactory qw( produce_contract );
use Finance::Contract::Longcode qw(
    shortcode_to_parameters
);

subtest 'shortcode_to_parameters' => sub {
    my $frxUSDJPY = 'frxUSDJPY';

    my $legacy = shortcode_to_parameters('DOUBLEDBL_frxUSDJPY_100_10_OCT_12_I_10H10_U_11H10_D_12H10', 'USD');
    is($legacy->{bet_type}, 'Invalid', 'Legacy shortcode.');

    my $rmg_dated_call = shortcode_to_parameters('CALL_frxUSDJPY_100_10_OCT_12_17_OCT_12_S1P_S2P', 'USD');
    is($legacy->{bet_type}, 'Invalid', 'Legacy shortcode.');

    my $call = shortcode_to_parameters('CALL_frxUSDJPY_100.00_1352351000_1352354600_S1P_S2P', 'USD');
    my $expected = {
        underlying                 => $frxUSDJPY,
        high_barrier               => 'S1P',
        shortcode                  => 'CALL_frxUSDJPY_100.00_1352351000_1352354600_S1P_S2P',
        low_barrier                => 'S2P',
        date_expiry                => '1352354600',
        bet_type                   => 'CALL',
        currency                   => 'USD',
        date_start                 => '1352351000',
        amount_type                => 'payout',
        amount                     => '100.00',
        fixed_expiry               => undef,
        is_sold                    => 0,
        starts_as_forward_starting => 0,
    };
    cmp_deeply($call, $expected, 'CALL shortcode.');

    my $legacy_put = shortcode_to_parameters('PUT_frxUSDJPY_100.00_1352351000_9_NOV_12_80_90', 'USD');
    is($legacy_put->{bet_type}, 'Invalid', 'Legacy shortcode.');
    my $put = shortcode_to_parameters('PUT_frxUSDJPY_100.00_1352351000_1352494800_80_90', 'USD');
    is($put->{bet_type},    'PUT',                                 'parsed bet_type');
    is($put->{date_start},  Date::Utility->new(1352351000)->epoch, 'parsed start time');
    is($put->{date_expiry}, '1352494800',                          'parsed expiry time');

    my $tickup = shortcode_to_parameters('CALL_frxUSDJPY_100.00_1352351000_9T_0_0', 'USD');
    $expected = {
        underlying                 => $frxUSDJPY,
        barrier                    => '0',
        shortcode                  => 'CALL_frxUSDJPY_100.00_1352351000_9T_0_0',
        bet_type                   => 'CALL',
        currency                   => 'USD',
        date_start                 => '1352351000',
        amount_type                => 'payout',
        amount                     => '100.00',
        fixed_expiry               => undef,
        duration                   => '9t',
        is_sold                    => 0,
        starts_as_forward_starting => 0,
    };
    cmp_deeply($tickup, $expected, 'FLASH tick expiry shortcode.');

    $call = shortcode_to_parameters('CALL_frxUSDJPY_100.00_1352351000_1352354600_S1P_S2P', 'USD', 1);
    $expected = {
        underlying                 => $frxUSDJPY,
        high_barrier               => 'S1P',
        shortcode                  => 'CALL_frxUSDJPY_100.00_1352351000_1352354600_S1P_S2P',
        low_barrier                => 'S2P',
        date_expiry                => '1352354600',
        bet_type                   => 'CALL',
        currency                   => 'USD',
        date_start                 => '1352351000',
        amount_type                => 'payout',
        amount                     => '100.00',
        fixed_expiry               => undef,
        is_sold                    => 1,
        starts_as_forward_starting => 0,
    };
    cmp_deeply($call, $expected, 'CALL shortcode. for is_sold');
};

1;
