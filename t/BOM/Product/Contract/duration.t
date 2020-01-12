#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;

use Test::Fatal;
use BOM::Product::ContractFactory qw(produce_contract);

subtest 'everything about duration/date_expiry' => sub {
    my $args = {
        bet_type   => 'CALL',
        underlying => 'R_100',
        barrier    => 'S0P',
        currency   => 'USD',
        payout     => 100,
    };

    my $error = exception { produce_contract($args) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Please specify either [_1] or [_2].', 'not duration or date_expiry specified';

    $error = exception { produce_contract({%$args, date_start => '30-Dec-18', duration => 0, date_expiry => '2030-01-01'}) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Please specify either [_1] or [_2].', 'not duration or date_expiry specified';

    $args->{date_expiry} = '05-JAN-19';
    $error = exception { produce_contract($args) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Expiry time cannot be in the past.', 'expiry in the past';

    $args->{underlying} = 'frxUSDJPY';
    $args->{date_start} = '30-DEC-18';

    $error = exception { produce_contract($args) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'The contract must expire on a trading day.', 'expire on non-trading day';

    delete $args->{date_start};
    delete $args->{date_expiry};

    $args->{duration} = 0;

    $error = exception { produce_contract($args) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Trading is not offered for this duration.', 'zero duration';

    $args->{duration} = '10x';

    $error = exception { produce_contract($args) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Trading is not offered for this duration.', 'zero duration';

    delete $args->{duration};

    lives_ok { produce_contract({%$args, duration    => '1t'}) } 'duration 1t';
    lives_ok { produce_contract({%$args, duration    => '1s'}) } 'duration 1s';
    lives_ok { produce_contract({%$args, duration    => '1m'}) } 'duration 1m';
    lives_ok { produce_contract({%$args, duration    => '1h'}) } 'duration 1h';
    lives_ok { produce_contract({%$args, duration    => '1d'}) } 'duration 1d';
    lives_ok { produce_contract({%$args, date_expiry => time + 5000}) } 'date_expiry 5000 seconds in the future';
};

done_testing();
