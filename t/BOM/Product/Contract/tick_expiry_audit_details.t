#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 6;
use Test::Warnings;
use Test::Exception;
use Test::MockModule;
use File::Spec;
use File::Slurp;
use Data::Dumper;

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Config::Runtime;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

my $json = JSON::MaybeXS->new;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_100',
        date   => Date::Utility->new
    });
my $one_day = Date::Utility->new('2014-07-10 10:00:00');

for (0 .. 1) {
    my $epoch = $one_day->epoch + $_ * 2;
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $epoch,
        quote      => 100 + $_
    });
}

subtest 'tick expiry up&down' => sub {
    my $args = {
        underlying   => 'R_100',
        bet_type     => 'CALL',
        date_start   => $one_day,
        date_pricing => $one_day->plus_time_interval('2s'),
        duration     => '5t',
        currency     => 'USD',
        payout       => 100,
        barrier      => 'S0P',
    };

    my $c = produce_contract($args);

    $args->{date_pricing} = $one_day->plus_time_interval('4s');

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + 2 * 2,
        quote      => 100 + 2
    });

    $c = produce_contract($args);
    ok !$c->is_expired, 'not expired when exit tick is undef';

    for (3 .. 5) {
        my $epoch = $one_day->epoch + $_ * 2;
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $epoch,
            quote      => 100 + $_
        });
    }

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + 6 * 2,
        quote      => 111
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + 7 * 2,
        quote      => 112
    });

    $args->{date_pricing} = $one_day->plus_time_interval('6s');
    $c = produce_contract($args);

    delete $args->{date_pricing};
    my $c2 = produce_contract($args);
    ok $c2->is_expired, 'contract is expired once exit tick is obtained';
    is $c2->exit_tick->quote, 111, 'exit tick is the 6th tick after contract start time';

    my $expected = $json->decode(
        '{"all_ticks":[{"name":["Start Time"],"flag":"highlight_time","epoch":1404986400,"tick":"100.00"},{"flag":"highlight_tick","epoch":1404986402,"name":["Entry Spot"],"tick":"101.00"},{"tick":"102.00","epoch":1404986404},{"tick":"103.00","epoch":1404986406},{"tick":"104.00","epoch":1404986408},{"tick":"105.00","epoch":1404986410},{"name":["[_1] and [_2]","End Time","Exit Spot"],"epoch":1404986412,"flag":"highlight_tick","tick":"111.00"},{"epoch":1404986414,"tick":"112.00"}]}'
    );

    is_deeply($c2->audit_details, $expected, 'audit details as expected');
};

my $new_day = $one_day->plus_time_interval('1d');
for (0 .. 4) {
    my $epoch = $new_day->epoch + $_ * 2;
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $epoch,
        quote      => 100 + $_
    });
}

subtest 'tick expiry digits' => sub {
    my $args = {
        underlying   => 'R_100',
        bet_type     => 'DIGITMATCH',
        date_start   => $new_day,
        date_pricing => $new_day->plus_time_interval('4s'),
        duration     => '5t',
        currency     => 'USD',
        payout       => 100,
        barrier      => 8,
    };
    my $c = produce_contract($args);
    ok !$c->exit_tick,  'exit tick is undef when we only have 4 ticks';
    ok !$c->is_expired, 'not expired when exit tick is undef';
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $new_day->epoch + 5 * 2,
        quote      => 111
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $new_day->epoch + 6 * 2,
        quote      => 112
    });
    delete $args->{date_pricing};
    my $c2 = produce_contract($args);
    ok $c2->is_expired, 'contract is expired once exit tick is obtained';
    is $c2->exit_tick->quote, 111, 'exit tick is the 6th tick after contract start time';

    my $expected = $json->decode(
        '{"all_ticks":[{"tick":"112.00","epoch":1404986414},{"flag":"highlight_time","epoch":1405072800,"name":["Start Time"],"tick":"100.00"},{"tick":"101.00","epoch":1405072802,"flag":"highlight_tick","name":["Entry Spot"]},{"tick":"102.00","epoch":1405072804},{"tick":"103.00","epoch":1405072806},{"tick":"104.00","epoch":1405072808},{"flag":"highlight_tick","epoch":1405072810,"name":["[_1] and [_2]","End Time","Exit Spot"],"tick":"111.00"},{"epoch":1405072812,"tick":"112.00"}]}'
    );

    is_deeply($c2->audit_details, $expected, 'audit details as expected');
};

subtest 'asian' => sub {
    lives_ok {
        my $time   = Date::Utility->new(1310631887);
        my $c      = produce_contract('ASIANU_R_75_5_1310631887_2T', 'USD');
        my $params = $c->build_parameters;
        $params->{date_pricing} = $c->date_start->epoch + 299;
        $c = produce_contract($params);
        ok !$c->is_after_settlement, 'is not expired';

        # add ticks
        for (1 .. 3) {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                underlying => 'R_75',
                epoch      => $time->epoch + $_ * 2,
                quote      => 100 + $_,
            });
        }

        $c = produce_contract('ASIANU_R_75_5_1310631887_2T', 'USD');
        ok $c->is_after_settlement, 'is expired';

        my $expected = $json->decode(
            '{"all_ticks":[{"name":["Entry Spot"],"flag":"highlight_tick","epoch":1310631889,"tick":"101.0000"},{"flag":"highlight_tick","epoch":1310631891,"name":["[_1] and [_2]","End Time","Exit Spot"],"tick":"102.0000"},{"tick":"103.0000","epoch":1310631893}]}'
        );

        is_deeply($c->audit_details, $expected, 'audit details as expected');
    }
    'build from shortcode';
};

$one_day = Date::Utility->new('2015-02-10 10:00:00');

for (0 .. 1) {
    my $epoch = $one_day->epoch + $_ * 2;
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $epoch,
        quote      => 100 + $_
    });
}

subtest 'tick expiry one touch no touch' => sub {
    my $args = {
        underlying   => 'R_100',
        bet_type     => 'ONETOUCH',
        date_start   => $one_day,
        duration     => '5t',
        date_pricing => $one_day,
        currency     => 'USD',
        payout       => 100,
        barrier      => '+2.0'
    };

    # Here we simulate proposal by using duration instead of tick_expiry and tick_count
    $args->{date_pricing} = $one_day->plus_time_interval('2s');

    my $c = produce_contract($args);
    ok !$c->is_expired, 'We are at the same second as the entry tick';

    $args->{barrier} = '+1.0';
    $c = produce_contract($args);
    ok !$c->is_expired, 'We are at the same second as the entry tick';

    for (2 .. 5) {

        my $index = $_;

        $args->{barrier}      = '+' . $index . '.0';
        $args->{date_pricing} = $one_day->plus_time_interval(($index * 2) . 's');

        # Before next tick is available
        $c = produce_contract($args);
        ok !$c->is_expired, 'contract did not touch barrier';

        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $one_day->epoch + $index * 2,
            quote      => 101 + $index
        });

        # After tick become available, hit the barrier test.
        $c = produce_contract($args);
        ok $c->is_expired, 'contract is expired once it touch the barrier';

        # No barrier hit test case
        $args->{barrier} = '+' . ($index + 0.02);
        $c = produce_contract($args);
        ok !$c->is_expired, 'contract did not touch barrier';

    }

    #Here we are at right before the last tick
    $args->{barrier}      = '+7.0';
    $args->{date_pricing} = $one_day->plus_time_interval('12s');

    $c = produce_contract($args);
    ok !$c->is_expired, 'contract did not touch barrier and not expired, this is right before our last tick';

    # And here is the last tick
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + 6 * 2,
        quote      => 108
    });

    $c = produce_contract($args);
    ok $c->is_expired, 'Here is the last one, 5th tick after entry tick';

    $args->{barrier} = '-1.0';
    $c = produce_contract($args);
    ok $c->is_expired, 'Here is the last one, 5th tick after entry tick';

    my $expected = $json->decode(
        '{"all_ticks":[{"tick":"100.00","epoch":1423562400,"flag":"highlight_time","name":["Start Time"]},{"tick":"101.00","epoch":1423562402,"flag":"highlight_tick","name":["Entry Spot"]},{"tick":"103.00","epoch":1423562404},{"tick":"104.00","epoch":1423562406},{"tick":"105.00","epoch":1423562408},{"epoch":1423562410,"tick":"106.00"},{"tick":"108.00","epoch":1423562412,"flag":"highlight_tick","name":["[_1] and [_2]","End Time","Exit Spot"]}]}'
    );

    is_deeply($c->audit_details, $expected, 'audit details as expected');
};

my $now = Date::Utility->new;

my $tick_runs = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_100',
    epoch      => $now->epoch,
    quote      => 99
});

my $args_runs = {
    bet_type     => 'RUNHIGH',
    date_start   => $now,
    date_pricing => $now,
    underlying   => 'R_100',
    duration     => '2t',
    currency     => 'USD',
    payout       => 100,
    barrier      => 'S0P',
};

subtest 'runs audit details' => sub {
    _create_ticks($now->epoch, [100]);    # [entry_tick]
    $args_runs->{date_pricing} = $now->epoch + 1;
    $args_runs->{duration}     = '1t';
    my $c = produce_contract($args_runs);
    ok $c->entry_tick, 'has entry tick';
    ok $c->entry_tick->quote == $c->barrier->as_absolute, 'barrier = entry spot';
    ok !$c->is_expired, 'not expired';
    _create_ticks($now->epoch, [100, 100]);    # [entry_tick, first_tick]
    $c = produce_contract($args_runs);
    ok $c->is_expired, 'expired';
    is $c->value, 0, 'expired worthless if first tick is equals to barrier';
    _create_ticks($now->epoch, [100, 101, 101]);    # [entry_tick, first_tick ...]
    $args_runs->{duration} = '2t';
    $c = produce_contract($args_runs);
    ok $c->is_expired, 'expired';
    is $c->value, 0, 'expired worthless if first and second ticks are equal';
    _create_ticks($now->epoch, [100, 101, 100]);    # [entry_tick, first_tick ...]
    $args_runs->{duration} = '2t';
    _create_ticks($now->epoch, [100, 101, 103, 102, 105]);    # [entry_tick, first_tick ...]
    $args_runs->{duration} = '5t';
    $c = produce_contract($args_runs);
    ok $c->is_expired, 'expired';
    is $c->value, 0, 'expired worthless if third tick is lower than second tick without a complete set of ticks';
    $c = produce_contract($args_runs);
    ok $c->is_expired, 'expired';
    is $c->value, 0, 'expired worthless if second tick is lower than first tick';
    _create_ticks($now->epoch, [100, 101, 102, 103]);         # [entry_tick, first_tick ...]
    $args_runs->{duration} = '5t';
    $c = produce_contract($args_runs);
    ok !$c->is_expired, 'not expired if we only have 3 out of 5 ticks';
    _create_ticks($now->epoch, [100, 101, 102, 102, 103]);    # [entry_tick, first_tick ...]
    $args_runs->{duration} = '5t';
    $c = produce_contract($args_runs);
    ok $c->is_expired, 'expired';
    is $c->value, 0, 'expired worthless 2 out of the 4 ticks are identical in a 5-tick contract';
    _create_ticks($now->epoch, [100, 101, 102, 103, 104, 105]);    # [entry_tick, first_tick ...]
    $args_runs->{duration} = '5t';
    $c = produce_contract($args_runs);
    ok $c->is_expired, 'expired';
    is $c->value, 100, 'expired with full payout if the next 5 ticks are higher than the previous tick';

    my $expected =
        $json->decode('{"all_ticks":[{"tick":"100.00","epoch":'
            . ($now->epoch + 1)
            . ',"name":["Entry Spot"],"flag":"highlight_tick"},{"tick":"101.00","epoch":'
            . ($now->epoch + 2)
            . '},{"tick":"102.00","epoch":'
            . ($now->epoch + 3)
            . '},{"epoch":'
            . ($now->epoch + 4)
            . ',"tick":"103.00"},{"epoch":'
            . ($now->epoch + 5)
            . ',"tick":"104.00"},{"epoch":'
            . ($now->epoch + 6)
            . ',"tick":"105.00","name":["[_1] and [_2]","End Time","Exit Spot"],"flag":"highlight_tick"}]}');

    is_deeply($c->audit_details, $expected, 'audit details as expected');
};

sub _create_ticks {
    my ($epoch, $quotes) = @_;

    BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;
    foreach my $q (@$quotes) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => ++$epoch,
            quote      => $q
        });
    }
    return;
}

