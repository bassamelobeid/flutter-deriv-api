#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use BOM::Product::ContractFactory qw(produce_contract);
use Try::Tiny;

subtest 'amount_type - generic' => sub {
    my $args = {
        bet_type   => 'CALL',
        underlying => 'R_100',
        barrier    => 'S0P',
        duration   => '5m',
        currency   => 'USD',
    };

    try { produce_contract($args) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Please specify either [_1] or [_2].', 'no payout or stake specify';
    };

    $args->{payout}     = 1;
    $args->{multiplier} = 1;

    try { produce_contract($args) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], '[_1] is not a valid input for contract type [_2].', 'specify multiplier for CALL';
        is $_->message_to_client->[1], 'multiplier';
        is $_->message_to_client->[2], 'CALL';
    };

    delete $args->{payout};
    $args->{bet_type} = 'CALLSPREAD';
    $args->{stake}    = 100;
    delete $args->{barrier};
    $args->{high_barrier} = 'S10P';
    $args->{low_barrier}  = 'S-10P';
    try { produce_contract($args) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Basis must be [_1] for this contract.', 'specify stake for CALLSPREAD';
        is $_->message_to_client->[1], 'payout';
    };

    $args->{bet_type} = 'LBFLOATCALL';
    delete $args->{high_barrier};
    delete $args->{low_barrier};

    try { produce_contract($args) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], '[_1] is not a valid input for contract type [_2].', 'specify stake for LBFLOATCALL';
        is $_->message_to_client->[1], 'basis';
        is $_->message_to_client->[2], 'LBFLOATCALL';
    };

    $args->{bet_type} = 'CALL';
    $args->{barrier}  = 'S0P';

    try { produce_contract({%$args, payout => 100}) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Please specify either [_1] or [_2].', 'specify stake and payout for CALL';
    };

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

    try { produce_contract({%$args, payout => 0}) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Invalid stake/payout.', 'zero payout not valid';
    };

    try { produce_contract({%$args, stake => 0}) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Invalid stake/payout.', 'zero stake not valid';
    };

    try { produce_contract({%$args, amount_type => 'payout', amount => 0}) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Invalid stake/payout.', 'zero stake not valid';
    };

    try { produce_contract({%$args, amount_type => 'stake', amount => 0}) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Invalid stake/payout.', 'zero stake not valid';
    };

    delete $args->{barrier};
    $args->{bet_type}   = 'LBFLOATCALL';
    $args->{multiplier} = 0;

    try { produce_contract($args) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Minimum multiplier of [_1].', 'zero multiplier not valid';
        is $_->message_to_client->[1], 0.2;
    };

};

done_testing();
