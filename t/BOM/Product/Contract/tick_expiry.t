#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 4;
use Test::Warnings;
use Test::Exception;
use Test::MockModule;
use File::Spec;
use File::Slurp;

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
        payout       => 100
    };

    my $c = produce_contract($args);

    is scalar(@{$c->get_ticks_for_tick_expiry}), 1 , 'correct no of tick for streaming';

    $args->{date_pricing} = $one_day->plus_time_interval('4s');

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + 2 * 2,
        quote      => 100 + 2
    });

    $c = produce_contract($args);
    ok $c->tick_expiry, 'is tick expiry contract';
    is $c->tick_count, 5, 'number of ticks is 5';
    ok !$c->exit_tick,  'exit tick is undef when we only have 5 ticks';
    ok !$c->is_expired, 'not expired when exit tick is undef';

    is scalar(@{$c->get_ticks_for_tick_expiry}), 2 , 'correct no of tick for streaming';    

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

    my $expected3 = $json->decode(
        '[{"epoch":1404986402,"tick":"101.00"},{"epoch":1404986404,"tick":"102.00"},{"tick":"103.00","epoch":1404986406}]'
    );

    delete $args->{date_pricing};
    my $c2 = produce_contract($args);
    ok $c2->is_expired, 'contract is expired once exit tick is obtained';
    is $c2->exit_tick->quote, 111, 'exit tick is the 6th tick after contract start time';

    is scalar(@{$c->get_ticks_for_tick_expiry}), 6 , 'correct no of tick for streaming';
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
    ok $c->tick_expiry, 'is tick expiry contract';
    is $c->tick_count, 5, 'number of ticks is 5';
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
    is $c2->exit_tick->quote,     111, 'exit tick is the 6th tick after contract start time';
    is $c2->barrier->as_absolute, 8,   'barrier is 8';
};

subtest 'asian' => sub {
    lives_ok {
        my $time   = Date::Utility->new(1310631887);
        my $c      = produce_contract('ASIANU_R_75_5_1310631887_2T', 'USD');
        my $params = $c->build_parameters;
        $params->{date_pricing} = $c->date_start->epoch + 299;
        $c = produce_contract($params);
        is $c->code, 'ASIANU', 'extracted the right bet type from shortcode';
        is $c->underlying->symbol, 'R_75', 'extracted the right symbol from shortcode';
        is $c->payout, 5, 'correct payout from shortcode';
        is $c->date_start->epoch, 1310631887, 'correct start time';
        is $c->tick_count, 2, 'correct number of ticks';
        ok $c->tick_expiry, 'is a tick expiry contract';
        ok !$c->is_after_settlement, 'is not expired';
        is $c->barrier, undef, 'barrier is undef';

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
        is $c->underlying->pip_size, 0.0001, 'underlying pip size';
        cmp_ok $c->barrier->as_absolute, '==', 101.50000, 'correct barrier with one more decimal in pip size';
    }
    'build from shortcode';

    lives_ok {
        my $c = produce_contract('ASIANU_R_50_100_1466496619_5T_S5P_0', 'USD');
        is $c->shortcode, 'ASIANU_R_50_100_1466496619_5T', 'shortcode is without barrier';
    }
    'build from shortcode with relative barrier fails';

    lives_ok {
        my $c = produce_contract('ASIANU_R_50_100_1466496590_5T_1002000000_0', 'USD');
        is $c->shortcode, 'ASIANU_R_50_100_1466496590_5T', 'shortcode is without barrier';
    }
    'build from shortcode with absolute barrier fails';
};
