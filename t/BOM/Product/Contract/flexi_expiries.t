#!/usr/bin/perl

use strict;
use warnings;

use Test::More (tests => 6);
use Test::Exception;
use Test::NoWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);
use BOM::Product::ContractFactory qw( produce_contract );
use Date::Utility;
use BOM::Market::Underlying;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => Date::Utility->new('2014-03-04 11:45:00')->epoch,
    underlying => 'frxUSDJPY'
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => Date::Utility->new('2014-03-04 12:00:00')->epoch,
    underlying => 'frxUSDJPY'
});

my $currency = 'USD';
my $now      = Date::Utility->new('2014-03-04 12:00:00');

subtest 'flexi expiries flashs' => sub {
    my %params = (
        underlying   => 'frxUSDJPY',
        date_start   => $now,
        date_pricing => $now,
        date_expiry  => $now->plus_time_interval('3h'),
        bet_type     => 'FLASHU',
        payout       => 100,
        currency     => $currency,
    );
    my $contract = produce_contract(\%params);
    ok($contract->is_intraday,   'is an intraday bet');
    ok(!$contract->expiry_daily, 'not an expiry daily bet');
    like($contract->longcode, qr/3 hours after contract start time/, 'correct longcode for flexi expiry intraday');

    $params{date_expiry} = $now->truncate_to_day->plus_time_interval('23h59m59s');
    $contract = produce_contract(\%params);
    ok($contract->is_intraday,   'is an intraday bet');
    ok(!$contract->expiry_daily, 'not an expiry daily bet');
    like($contract->longcode, qr/11 hours 59 minutes 59 seconds after contract start time/, 'correct longcode for flexi expiry eod');

    $params{date_expiry}  = $now->truncate_to_day->plus_time_interval('12h30m');
    $params{fixed_expiry} = 1;
    $contract             = produce_contract(\%params);
    ok($contract->is_intraday,   'is an intraday bet');
    ok(!$contract->expiry_daily, 'not an expiry daily bet');
    like($contract->longcode, qr/at 2014-03-04 12:30:00/, 'correct longcode for fixed expiry');
};

subtest 'flexi expiries forward starting' => sub {
    my %params = (
        underlying   => 'frxUSDJPY',
        date_start   => $now,
        date_pricing => $now->minus_time_interval('15m'),
        date_expiry  => $now->plus_time_interval('1h'),
        bet_type     => 'INTRADU',
        payout       => 100,
        currency     => $currency,
    );
    my $contract = produce_contract(\%params);
    ok($contract->is_intraday,   'is an intraday bet');
    ok(!$contract->expiry_daily, 'not an expiry daily bet');
    like($contract->longcode, qr/1 hour after 2014-03-04 12:00:00/, 'correct longcode for flexi expiry forward starting');

    $params{fixed_expiry} = 1;
    $contract = produce_contract(\%params);
    ok($contract->is_intraday,   'is an intraday bet');
    ok(!$contract->expiry_daily, 'not an expiry daily bet');
    like($contract->longcode, qr/1 hour after 2014-03-04 12:00:00/, 'correct longcode for fixed expiry forward starting');
};

subtest 'flexi expiries mutliday contracts' => sub {
    my %params = (
        underlying   => 'frxUSDJPY',
        date_start   => $now,
        date_pricing => $now->minus_time_interval('15m'),
        date_expiry  => $now->truncate_to_day->plus_time_interval('1d23h59m59s'),
        bet_type     => 'DOUBLEUP',
        payout       => 100,
        currency     => $currency,
    );
    my $contract = produce_contract(\%params);
    ok(!$contract->is_intraday, 'not an intraday bet');
    ok($contract->expiry_daily, 'is an expiry daily bet');
    like($contract->longcode, qr/at close on 2014-03-05/, 'correct longcode for multiday flexi expiry');

    $params{fixed_expiry} = 1;
    $params{date_expiry}  = $now->truncate_to_day->plus_time_interval('2d10h30m');
    $contract             = produce_contract(\%params);
    ok(!$contract->is_intraday, 'not an intraday bet');
    ok($contract->expiry_daily, 'not an expiry daily bet');
    like($contract->longcode, qr/at 2014-03-06 10:30:00/, 'correct longcode for multiday flexi expiry');
};

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => Date::Utility->new('2014-03-23')->epoch,
    quote      => 100
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => Date::Utility->new('2014-03-23')->epoch + 1,
    quote      => 100
});
subtest 'correct expiry on holiday' => sub {
    my %params = (
        underlying   => 'frxUSDJPY',
        date_start   => '2014-03-23',
        date_pricing => '2014-03-23 00:00:01',
        date_expiry  => '2014-03-30 23:59:59',
        bet_type     => 'DOUBLEUP',
        payout       => 100,
        currency     => $currency,
    );

    lives_ok {
        my $contract = produce_contract(\%params);
        ok($contract->expiry_daily, 'is an expiry daily contract');
        ok(!$contract->is_intraday, 'it is not an intraday contract');
        like($contract->longcode, qr/at close on 2014-03-30/, 'longcode showing exact end time at close on holiday');
    }
    'does not die when expiry is on non-trading day';

    my $shortcode = 'DOUBLEDOWN_FRXUSDJPY_100_1395532800_9_JUL_14_S0P_0';
    lives_ok {
        my $contract = produce_contract($shortcode, 'USD');
        is($contract->date_expiry->datetime, '2014-07-09 23:59:59', 'correct expiry datetime');
        ok($contract->expiry_daily, 'is an expiry_daily contract');
        ok(!$contract->is_intraday, 'is not an intraday contract');
        like($contract->longcode, qr/at close on 2014-07-09/, 'correct longcode for legacy shortcode');
    }
};

subtest 'build the correct shortcode' => sub {
    my %params = (
        underlying   => 'frxUSDJPY',
        date_start   => '2014-03-23',
        date_pricing => '2014-03-23 00:00:01',
        date_expiry  => '2014-03-30 23:59:59',
        bet_type     => 'DOUBLEUP',
        payout       => 100,
        currency     => $currency,
        fixed_expiry => 1,
        barrier      => 'S0P'
    );
    lives_ok {
        my $contract = produce_contract(\%params);
        is($contract->shortcode, 'CALL_FRXUSDJPY_100_1395532800_1396223999F_S0P_0', 'correct shortcode for fixed expiry contracts');
        $contract = produce_contract('DOUBLEUP_FRXUSDJPY_100_1395532800_1396223999F_S0P_0', $currency);
        ok($contract->fixed_expiry, 'correctly convert shortcode to fixed expiry contract');
        delete $params{fixed_expiry};
        $contract = produce_contract(\%params);
        is($contract->shortcode, 'CALL_FRXUSDJPY_100_1395532800_1396223999_S0P_0', 'correct shortcode for non-fixed expiry contracts');
        $contract = produce_contract('DOUBLEUP_FRXUSDJPY_100_1395532800_1396223999_S0P_0', $currency);
        ok(!$contract->fixed_expiry, 'non-fixed expiry if no _F');
    }
    'produce the correct shortcode';
};
