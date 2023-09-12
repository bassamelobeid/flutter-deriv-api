#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::FailWarnings;

use BOM::Config::Chronicle;
use BOM::Config::QuantsConfig;
use BOM::Product::ContractFactory                qw(produce_contract);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);

my $offerings = LandingCompany::Registry->by_name('virtual')->basic_offerings({
    loaded_revision => 1,
    action          => 'buy'
});
my @symbols = $offerings->query({contract_category => 'multiplier'}, ['underlying_symbol']);

subtest 'multiplier range' => sub {
    my $expected = {
        'frxEURJPY' => [30,  50,   100,  150, 300],
        'frxAUDUSD' => [50,  100,  150,  250, 500],
        'R_25'      => [50,  100,  150,  250, 500],
        'frxGBPAUD' => [20,  30,   50,   100, 200],
        'frxUSDJPY' => [50,  100,  150,  250, 500],
        'frxUSDCHF' => [50,  100,  150,  250, 500],
        'R_50'      => [20,  40,   60,   100, 200],
        'frxEURCAD' => [20,  30,   50,   100, 200],
        'frxGBPUSD' => [50,  100,  150,  250, 500],
        'R_10'      => [100, 200,  300,  500, 1000],
        'frxEURGBP' => [30,  50,   100,  150, 300],
        'frxEURUSD' => [50,  100,  150,  250, 500],
        'frxGBPJPY' => [30,  50,   100,  150, 300],
        'R_75'      => [15,  30,   50,   75,  150],
        'frxEURAUD' => [20,  30,   50,   100, 200],
        'frxAUDJPY' => [20,  30,   50,   100, 200],
        'frxEURCHF' => [20,  30,   50,   100, 200],
        'R_100'     => [10,  20,   30,   50,  100],
        '1HZ10V'    => [100, 200,  300,  500, 1000],
        '1HZ25V'    => [50,  100,  150,  250, 500],
        '1HZ50V'    => [20,  40,   60,   100, 200],
        '1HZ75V'    => [15,  30,   50,   75,  150],
        '1HZ100V'   => [10,  20,   30,   50,  100],
        'frxUSDCAD' => [50,  100,  150,  250, 500],
        CRASH1000   => [100, 200,  300,  400],
        CRASH500    => [100, 200,  300,  400],
        BOOM1000    => [100, 200,  300,  400],
        BOOM500     => [100, 200,  300,  400],
        stpRNG      => [500, 1000, 2000, 3000, 4000],
        WLDEUR      => [50,  100,  150,  250,  500],
        WLDUSD      => [50,  100,  150,  250,  500],
        WLDGBP      => [30,  50,   100,  150,  300],
        WLDAUD      => [20,  30,   50,   100,  200],
        WLDXAU      => [15,  30,   50,   75,   150],
        cryBTCUSD   => [10,  20,   30,   40,   50],
        cryETHUSD   => [10,  20,   30,   40,   50],
        cryBNBUSD   => [10,  20,   30],
        cryBCHUSD   => [10,  20,   30],
        cryLTCUSD   => [10,  20,   30],
        cryXRPUSD   => [10,  20,   30],
        cryEOSUSD   => [5,   10],
        cryZECUSD   => [5,   10],
        cryXMRUSD   => [5,   10],
        cryDSHUSD   => [5,   10],
        JD10        => [100, 200, 300, 500, 1000],
        JD25        => [50,  100, 150, 250, 500],
        JD50        => [20,  40,  60,  100, 200],
        JD75        => [15,  30,  50,  75,  150],
        JD100       => [10,  20,  30,  50,  100],
        '1HZ150V'   => [1,   2,   3,   4,   5],
        '1HZ200V'   => [1,   2,   3,   4,   5],
        '1HZ250V'   => [1,   2,   3,   4,   5],
        '1HZ300V'   => [1,   2,   3,   4,   5],
        'CRASH300N' => [1,   2,   3,   4,   5],
        'BOOM300N'  => [1,   2,   3,   4,   5],
    };
    my $args = {
        bet_type   => 'multup',
        stake      => 100,
        currency   => 'USD',
        multiplier => 100,
    };

    foreach my $symbol (@symbols) {
        $args->{underlying} = $symbol;
        if (my $range = $expected->{$symbol}) {
            foreach my $multiplier (@$range) {
                $args->{multiplier} = $multiplier;
                my $c = produce_contract($args);
                ok !$c->_validate_multiplier_range();
            }
        } else {
            fail "multiplier range config not found for $symbol";
        }
    }
};

my $now = Date::Utility->new('2023-08-21');
my $qc  = BOM::Config::QuantsConfig->new(
    chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader,
    chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer,
    recorded_date    => $now,
);

subtest 'custom multiplier range' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'frxUSDJPY']);
    my $args = {
        bet_type     => 'multup',
        stake        => 100,
        currency     => 'USD',
        date_start   => $now,
        date_pricing => $now,
        multiplier   => 50,
        underlying   => 'frxUSDJPY',
    };
    my $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy at multiplier=50';

    note "set custom multiplier range to min=100 & max=200";

    my %config = (
        test3 => {
            staff             => 'abc',
            name              => 'test3',
            underlying_symbol => ['frxUSDJPY'],
            start_time        => $now->epoch,
            end_time          => $now->plus_time_interval('1h')->epoch,
            min_multiplier    => 100,
            max_multiplier    => 200,
        });
    $qc->save_config('custom_multiplier_commission', \%config);

    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'multiplier out of range', 'message - multiplier out of range';
    is $c->primary_validation_error->message_to_client->[0], 'Multiplier is not in acceptable range. Accepts [_1].',
        'message_to_client - Multiplier is not in acceptable range. Accepts [_1].';
    is $c->primary_validation_error->message_to_client->[1], '100,150';

    $args->{multiplier} = 150;
    $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy if multiplier is in range.';

    note "move date pricing contract to 1 second after custom configuration";
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->plus_time_interval('1h')->epoch, 'frxUSDJPY']);
    $args->{date_start} = $args->{date_pricing} = $now->plus_time_interval('1h1s');
    $args->{multiplier} = 50;
    $c                  = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy with multiplier=50 when it does not fall under custom config period.';

    clear_config();

    note 'set custom multiplier range for currency symbol';
    %config = (
        test4 => {
            staff           => 'abc',
            name            => 'test4',
            currency_symbol => ['USD'],
            start_time      => $now->epoch,
            end_time        => $now->plus_time_interval('1h')->epoch,
            min_multiplier  => 100,
            max_multiplier  => 200,
        });
    $qc->save_config('custom_multiplier_commission', \%config);

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'frxGBPJPY']);
    $args->{underlying} = 'frxGBPJPY';
    $args->{multiplier} = 30;
    $args->{date_start} = $args->{date_pricing} = $now;
    $c                  = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy for unaffected underlying';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'frxEURUSD']);
    $args->{underlying} = 'frxEURUSD';
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'multiplier out of range', 'message - multiplier out of range';
    is $c->primary_validation_error->message_to_client->[0], 'Multiplier is not in acceptable range. Accepts [_1].',
        'message_to_client - Multiplier is not in acceptable range. Accepts [_1].';
    is $c->primary_validation_error->message_to_client->[1], '100,150';

    $args->{multiplier} = 150;
    $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy with multiplier set to 150';

    note "To test one sided multiplier range config";
    delete $config{test4}{max_multiplier};
    $qc->save_config('custom_multiplier_commission', \%config);
    $args->{multiplier} = 250;
    $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy when max_multiplier cap is removed';

    clear_config();
    # range not affected if commission is specified in config
    %config = (
        test4 => {
            staff                 => 'abc',
            name                  => 'test4',
            currency_symbol       => ['USD'],
            start_time            => $now->epoch,
            end_time              => $now->plus_time_interval('1h')->epoch,
            min_multiplier        => 100,
            max_multiplier        => 200,
            commission_adjustment => 3,
        });
    $qc->save_config('custom_multiplier_commission', \%config);

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'frxUSDJPY']);
    $args = {
        bet_type     => 'multup',
        stake        => 100,
        currency     => 'USD',
        date_start   => $now,
        date_pricing => $now,
        multiplier   => 50,
        underlying   => 'frxUSDJPY',
    };
    $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';

    clear_config();
    # disable all multiplier range
    %config = (
        test4 => {
            staff           => 'abc',
            name            => 'test4',
            currency_symbol => ['USD'],
            start_time      => $now->epoch,
            end_time        => $now->plus_time_interval('1h')->epoch,
            min_multiplier  => 5,
            max_multiplier  => 5,
        });
    $qc->save_config('custom_multiplier_commission', \%config);

    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'multiplier out of range', 'message - multiplier out of range';
    is $c->primary_validation_error->message_to_client->[0], 'Multiplier is not in acceptable range.',
        'message_to_client - Multiplier is not in acceptable range.';
};

sub clear_config {
    $qc->chronicle_writer->set('quants_config', 'commission', {}, $now->minus_time_interval('4h'));
}

done_testing();
