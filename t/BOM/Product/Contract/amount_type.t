#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use BOM::Product::ContractFactory qw(produce_contract);
use Test::Fatal;

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
    $error = exception { produce_contract($args) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], '[_1] is not a valid input for contract type [_2].', 'specify multiplier for CALL';
    is $error->message_to_client->[1], 'multiplier';
    is $error->message_to_client->[2], 'CALL';

    delete $args->{payout};
    $args->{bet_type} = 'CALLSPREAD';
    $args->{stake}    = 100;
    delete $args->{barrier};
    $args->{high_barrier} = 'S10P';
    $args->{low_barrier}  = 'S-10P';
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
    lives_ok { produce_contract({%$args, amount_type => 'stake', 'amount' => 100}) } 'live with amount_type=stake';
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
    is $error->message_to_client->[1], 0.2;

};

subtest 'max amount' => sub {
    my $args = {
        bet_type   => 'CALL',
        underlying => 'R_100',
        barrier    => 'S0P',
        duration   => '5m',
        currency   => 'USD',
        payout     => 50000.01,
    };

    my $error = exception { produce_contract({%$args}) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Maximum payout allowed is [_1].', 'payout too big';
    is $error->message_to_client->[1], '50000.00';

    delete $args->{payout};
    $args->{stake} = 100000;
    lives_ok { produce_contract({%$args}) };

    delete $args->{duration};
    delete $args->{barrier};
    $args->{bet_type}   = 'MULTUP';
    $args->{multiplier} = 100;
    $error = exception { produce_contract({%$args}) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Maximum stake allowed is [_1].', 'stake too big';
    is $error->message_to_client->[1], '2000.00';

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
    is $error->message_to_client->[1], '0.00000200';

    my $c = produce_contract({%$args, payout => 0.000002});
    isa_ok $c, 'BOM::Product::Contract::Call';
};

done_testing();
