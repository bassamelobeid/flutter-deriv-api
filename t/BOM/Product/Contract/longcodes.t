#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::Most;
use Test::Warnings qw/warning/;
use Test::Exception;
use Test::Warnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);
use BOM::Product::ContractFactory qw( produce_contract);
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );

subtest 'Proper form' => sub {
    my @shortcodes = (
        qw~
            CALL_RDBULL_100_1393816299_1393828299_S0P_0
            ONETOUCH_FRXAUDJPY_100_1394502374_1394509574_S133P_0
            CALL_FRXEURUSD_100_1394502338_1394509538_S0P_0
            CALL_FRXEURUSD_100_1394502112_1394512912_S0P_0
            CALL_FRXNZDUSD_100_1394502169_1394512969_S0P_0
            PUT_FRXUSDJPY_100_1394502298_1394513098_S0P_0
            CALL_FRXNZDUSD_100_1394502392_1394509592_S0P_0
            CALL_FRXEURNOK_100_1394503200_1394514000_S0P_0
            PUT_FRXEURNOK_100_1394502900_1394513700_S0P_0
            CALL_FRXUSDJPY_100_1394501981_1394573981_S0P_0
            ONETOUCH_FRXAUDJPY_100_1394502043_1394538043_S300P_0
            PUT_FRXEURNOK_100_1394590423_1394591143_S0P_0
            ~
    );
    my @currencies = ('USD', 'EUR', 'RUR');    # Inexhaustive, incorrect list: just to be sure the currency is not accidentally hard-coded.
    foreach my $currency (@currencies) {
        my $expected_standard_form = qr/Win payout if .*\.$/;                                   # Simplified standard form to which all should adhere.
                                                                                                # Can this be improved further?
        my $exepcted_legacy_from   = qr/Legacy contract. No further information is available.$/;
        my $params;
        foreach my $shortcode (@shortcodes) {
            my $c = produce_contract($shortcode, $currency);
            my $expected_longcode = $shortcode =~ /FLASH*|INTRA*|DOUBLE*/ ? $exepcted_legacy_from : $expected_standard_form;
            like($c->longcode->[0], $expected_longcode, $shortcode . ' => long code form appears ok');
        }
    }

    # pick few random one to check complete equality
    my $c = produce_contract($shortcodes[3], 'USD');
    is_deeply(
        $c->longcode,
        [
            'Win payout if [_1] is strictly higher than [_4] at [_3] after [_2].',
            'EUR/USD', ['contract start time'], ['3 hours'], ['entry spot']]);

    $c = produce_contract($shortcodes[10], 'EUR');
    is_deeply(
        $c->longcode,
        [
            'Win payout if [_1] touches [_4] through [_3] after [_2].',
            'AUD/JPY',
            ['contract start time'], ['10 hours'],
            ['entry spot plus [plural,_1,%d pip, %d pips]', 300]]);

    $c = produce_contract($shortcodes[-1], 'RUR');
    is_deeply(
        $c->longcode,
        [
            'Win payout if [_1] is strictly lower than [_4] at [_3] after [_2].',
            'EUR/NOK', ['contract start time'], ['12 minutes'], ['entry spot']]);
};

subtest 'longcode from params for forward starting' => sub {
    my $now = Date::Utility->new('2016-10-19 10:00:00');
    my $tick = Postgres::FeedDB::Spot::Tick->new({
        underlying => 'R_100',
        quote      => 100,
        epoch      => $now->epoch
    });
    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'R_100',
        date_start   => $now->plus_time_interval('10m'),
        date_pricing => $now,
        duration     => '10m',
        currency     => 'USD',
        barrier      => 'S0P',
        payout       => 10,
        fixed_expiry => 1,
        current_tick => $tick,
    });

    ok $c->is_forward_starting, 'is a forward starting contract';

    is_deeply(
        $c->longcode,
        [
            'Win payout if [_1] is strictly higher than [_4] at [_3] after [_2].',
            'Volatility 100 Index',
            ['2016-10-19 10:10:00 GMT'],
            ['10 minutes'], ['entry spot']]);
};

subtest 'longcode with \'difference\' as barrier' => sub {
    my $now  = Date::Utility->new('2016-10-19 10:00:00');
    my $tick = Postgres::FeedDB::Spot::Tick->new({
        underlying => 'R_100',
        quote      => 100,
        epoch      => $now->epoch
    });
    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'R_100',
        date_start   => $now->plus_time_interval('10m'),
        date_pricing => $now,
        duration     => '10m',
        currency     => 'USD',
        barrier      => '+0.32',
        payout       => 10,
        fixed_expiry => 1,
        current_tick => $tick,
    });
    is_deeply(
        $c->longcode,
        [
            'Win payout if [_1] is strictly higher than [_4] at [_3] after [_2].',
            'Volatility 100 Index',
            ['2016-10-19 10:10:00 GMT'],
            ['10 minutes'], ['entry spot plus [_1]', 0.32]]);
    $c = produce_contract({
        bet_type     => 'EXPIRYMISS',
        underlying   => 'R_100',
        date_start   => $now->plus_time_interval('10m'),
        date_pricing => $now,
        duration     => '10m',
        currency     => 'USD',
        high_barrier => '+0.32',
        low_barrier  => '-0.42',
        payout       => 10,
        fixed_expiry => 1,
        current_tick => $tick,
    });
    is_deeply(
        $c->longcode,
        [
            'Win payout if [_1] ends outside [_5] to [_4] at [_3].',
            'Volatility 100 Index',
            [],
            ['2016-10-19 10:20:00 GMT'],
            ['entry spot plus [_1]',  0.32],
            ['entry spot minus [_1]', 0.42],
        ]);
};

subtest 'zero barrier' => sub {
    my $now  = Date::Utility->new('2016-10-19 10:00:00');
    my $tick = Postgres::FeedDB::Spot::Tick->new({
        underlying => 'R_100',
        quote      => 100,
        epoch      => $now->epoch
    });
    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'R_100',
        date_start   => $now->plus_time_interval('10m'),
        date_pricing => $now,
        duration     => '10m',
        currency     => 'USD',
        barrier      => 0,
        payout       => 10,
        fixed_expiry => 1,
        current_tick => $tick,
    });
    is_deeply(
        $c->longcode,
        [
            'Win payout if [_1] is strictly higher than [_4] at [_3] after [_2].',
            'Volatility 100 Index',
            ['2016-10-19 10:10:00 GMT'],
            ['10 minutes'], '0.00'
        ]);
};

done_testing();

1;
