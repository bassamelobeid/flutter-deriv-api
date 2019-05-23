#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Product::ContractFactory qw(produce_contract produce_batch_contract);
use Try::Tiny;

subtest 'single contract' => sub {
    my $args = {
        underlying => 'R_100',
        duration   => '5m',
        currency   => 'USD',
        payout     => 100,
    };

    foreach my $bet_type (qw(CALL CALLE ONETOUCH RESETCALL RUNHIGH)) {
        $args->{bet_type} = $bet_type;
        try { produce_contract($args) }
        catch {
            isa_ok $_, 'BOM::Product::Exception';
            is $_->message_to_client->[0], 'Invalid barrier (Single barrier input is expected).', 'no barrier for ' . $bet_type;
        };
    }

    foreach my $bet_type (qw(EXPIRYMISS RANGE CALLSPREAD)) {
        $args->{bet_type} = $bet_type;
        try { produce_contract($args) }
        catch {
            isa_ok $_, 'BOM::Product::Exception';
            is $_->message_to_client->[0], 'Invalid barrier (Double barrier input is expected).', 'no barrier for ' . $bet_type;
        };
    }

    #barrier for the unexpected
    $args->{barrier} = 'S0P';
    foreach my $bet_type (qw(ASIANU DIGITEVEN TICKHIGH LBFLOATCALL)) {
        $args->{bet_type} = $bet_type;
        try { produce_contract($args) }
        catch {
            isa_ok $_, 'BOM::Product::Exception';
            is $_->message_to_client->[0], 'Barrier is not allowed for this contract type.', 'pass in barrier for ' . $bet_type;
        };
    }

    #double barrier for the single
    delete $args->{barrier};
    $args->{high_barrier} = 'S10P';
    $args->{low_barrier}  = 'S-10P';
    $args->{bet_type}     = 'CALL';

    try { produce_contract($args) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Invalid barrier (Single barrier input is expected).', 'double barrier for CALL';
    };

    #single barrier for the double
    delete $args->{high_barrier};
    delete $args->{low_barrier};
    $args->{barrier}  = 'S0P';
    $args->{bet_type} = 'RANGE';

    try { produce_contract($args) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Invalid barrier (Double barrier input is expected).', 'single barrier for RANGE';
    };
};

subtest 'batch contract' => sub {
    my $args = {
        underlying => 'R_100',
        duration   => '5m',
        currency   => 'USD',
        payout     => 100,
        bet_type   => 'CALL',
    };

    try { produce_batch_contract($args) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Invalid barrier.', 'no barriers for CALL';
    };

    $args->{barriers} = [{barrier => 'S0P'}, {barrier2 => 'S10P'}];
    try { produce_batch_contract($args) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Invalid barrier (Single barrier input is expected).', 'barrier2 for CALL';
    };
};

subtest 'zero relative & absolute barriers' => sub {
    my $args = {
        underlying => 'R_100',
        duration   => '5m',
        currency   => 'USD',
        payout     => 100,
        bet_type   => 'CALL',
        barrier    => 0
    };

    try { produce_contract($args) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Barrier cannot be zero.', 'zero barrier for CALL';
    };

    lives_ok { produce_contract({%$args, barrier => '+0'}) } '+0 barrier lives';
    lives_ok { produce_contract({%$args, barrier => '-0'}) } '-0 barrier lives';

    $args->{bet_type} = 'RANGE';
    delete $args->{barrier};
    $args->{high_barrier} = 0;
    $args->{low_barrier}  = 100;
    try { produce_contract($args) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Barrier cannot be zero.', 'zero high_barrier for RANGE';
    };

    $args->{high_barrier} = '+0';
    try { produce_contract($args) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Invalid barrier (Contract can have only one type of barrier).', 'mixed barrier for RANGE';
    };

    $args->{current_tick} = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => time,
        quote      => 100
    });

    lives_ok { produce_contract({%$args, high_barrier => '+0', low_barrier  => '-0.001'}) } '+0 high_barrier -0.001 low_barrier lives';
    lives_ok { produce_contract({%$args, low_barrier  => '-0', high_barrier => '+0.001'}) } '-0 low_barrier +0.001 high_barrier lives';

};

done_testing();
