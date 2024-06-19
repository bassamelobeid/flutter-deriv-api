#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use BOM::Product::ContractFactory qw(produce_contract);
use Test::Fatal;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);

my $redis_exchangerates = BOM::Config::Redis::redis_exchangerates_write();
$redis_exchangerates->hmset(
    'exchange_rates::BTC_USD',
    quote => 30000,
    epoch => time
);

my $current_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_100',
    quote      => 100,
    epoch      => time,
});

subtest 'amount_type - generic' => sub {
    my $args = {
        bet_type   => 'CALL',
        underlying => 'R_100',
        barrier    => 'S0P',
        duration   => '5m',
        currency   => 'USD',
    };

    my $error = exception { produce_contract($args) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Please specify either [_1] or [_2].', 'no payout or stake specify';

    $args->{payout}     = 1;
    $args->{multiplier} = 1;
    $error              = exception { produce_contract($args) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], '[_1] is not a valid input for contract type [_2].', 'specify multiplier for CALL';
    is $error->message_to_client->[1], 'multiplier';
    is $error->message_to_client->[2], 'CALL';

    delete $args->{payout};
    $args->{bet_type} = 'CALLSPREAD';
    $args->{stake}    = 100;
    delete $args->{barrier};
    $args->{barrier_range} = 'middle';
    $error = exception { produce_contract($args) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Basis must be [_1] for this contract.', 'specify stake for CALLSPREAD';
    is $error->message_to_client->[1], 'payout';

    $args->{bet_type} = 'LBFLOATCALL';
    delete $args->{high_barrier};
    delete $args->{low_barrier};

    $error = exception { produce_contract($args) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], '[_1] is not a valid input for contract type [_2].', 'specify stake for LBFLOATCALL';
    is $error->message_to_client->[1], 'basis';
    is $error->message_to_client->[2], 'LBFLOATCALL';

    $args->{bet_type} = 'CALL';
    $args->{barrier}  = 'S0P';

    $error = exception { produce_contract({%$args, payout => 100}) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Please specify either [_1] or [_2].', 'specify stake and payout for CALL';

    delete $args->{stake};
    delete $args->{multiplier};

    lives_ok { produce_contract({%$args, stake       => 100}) } 'live with stake';
    lives_ok { produce_contract({%$args, payout      => 100}) } 'live with payout';
    lives_ok { produce_contract({%$args, amount_type => 'stake',  'amount' => 100}) } 'live with amount_type=stake';
    lives_ok { produce_contract({%$args, amount_type => 'payout', 'amount' => 100}) } 'live with amount_type=payout';
};

subtest 'zero amount' => sub {
    my $args = {
        bet_type   => 'CALL',
        underlying => 'R_100',
        barrier    => 'S0P',
        duration   => '5m',
        currency   => 'USD',
    };

    my $error = exception { produce_contract({%$args, payout => 0}) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Please enter a payout amount that\'s at least [_1].', 'zero payout not valid';
    is $error->message_to_client->[1], '0.01';

    $error = exception { produce_contract({%$args, stake => 0}) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Please enter a stake amount that\'s at least [_1].', 'zero payout not valid';

    $error = exception { produce_contract({%$args, amount_type => 'payout', amount => 0}) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Please enter a payout amount that\'s at least [_1].', 'zero payout not valid';

    $error = exception { produce_contract({%$args, amount_type => 'stake', amount => 0}) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Please enter a stake amount that\'s at least [_1].', 'zero payout not valid';

    delete $args->{barrier};
    $args->{bet_type}   = 'LBFLOATCALL';
    $args->{multiplier} = 0;

    $error = exception { produce_contract($args) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Minimum multiplier of [_1].', 'zero multiplier not valid';
    is $error->message_to_client->[1], '0.50';

};

subtest 'max amount' => sub {
    my $args = {
        bet_type     => 'CALL',
        underlying   => 'R_100',
        barrier      => 'S0P',
        duration     => '5m',
        currency     => 'USD',
        payout       => 50000.01,
        current_tick => $current_tick,
    };

    my $bet = produce_contract({%$args});
    ok !$bet->is_valid_to_buy, 'not valid to buy';
    is $bet->primary_validation_error->message_to_client->[0], 'Minimum stake of [_1] and maximum payout of [_2]. Current payout is [_3].',
        'payout too big';
    is $bet->primary_validation_error->message_to_client->[1], '0.35';
    is $bet->primary_validation_error->message_to_client->[2], '50000.00';
    is $bet->primary_validation_error->message_to_client->[3], '50000.01';

    delete $args->{payout};
    $args->{stake} = 100000;
    lives_ok { produce_contract({%$args}) };

    delete $args->{duration};
    delete $args->{barrier};
    $args->{bet_type}   = 'MULTUP';
    $args->{multiplier} = 100;
    my $c = produce_contract({%$args});
    ok !$c->is_valid_to_buy;
    is $c->primary_validation_error->message_to_client->[0], 'Maximum stake allowed is [_1].', 'stake too big';
    is $c->primary_validation_error->message_to_client->[1], '2000.00';

};

subtest 'cryto amount' => sub {
    my $args = {
        bet_type   => 'CALL',
        underlying => 'R_100',
        barrier    => 'S0P',
        duration   => '5m',
        currency   => 'BTC',
    };

    my $error = exception { produce_contract({%$args, payout => 0}) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Please enter a payout amount that\'s at least [_1].', 'zero payout not valid';
    is $error->message_to_client->[1], '0.00000030';

    my $c = produce_contract({%$args, payout => 0.01000000});
    isa_ok $c, 'BOM::Product::Contract::Call';
};

subtest 'amount_type - forward starting' => sub {
    my $args = {
        bet_type   => 'CALL',
        underlying => 'R_100',
        barrier    => 'S0P',
        date_start => time + 100,
        duration   => '5m',
        currency   => 'USD',
    };

    my $error = exception { produce_contract($args) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Please specify either [_1] or [_2].', 'no payout or stake specify';

};

done_testing();
