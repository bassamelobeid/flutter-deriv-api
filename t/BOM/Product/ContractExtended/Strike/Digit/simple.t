#!/usr/bin/env perl

use Test::Most (tests => 2);
use Test::FailWarnings;

use BOM::Market::Data::Tick;
use BOM::Product::Contract::Strike::Digit;

subtest 'construction' => sub {
    my $test_symbol = 'frxUSDJPY';
    my $basis_tick  = BOM::Market::Data::Tick->new(
        epoch  => time,
        quote  => 100,
        symbol => $test_symbol,
    );

    my $strike = new_ok(
        'BOM::Product::Contract::Strike::Digit',
        [{
                basis_tick       => $basis_tick,
                supplied_barrier => 0,
            }
        ],
        'Seemingly normal'
    );

    is($strike->underlying->symbol, $test_symbol, 'Underlying is populated with symbol from basis tick if left off');

    $strike = new_ok(
        'BOM::Product::Contract::Strike::Digit',
        [{
                underlying       => 'R_100',
                basis_tick       => $basis_tick,
                supplied_barrier => 1,
            }
        ],
        'Mismatched underlying'
    );
    is($strike->underlying->symbol, 'R_100', 'Underlying supplied is different than basis tick does not blow up and uses given value.');

    throws_ok { BOM::Product::Contract::Strike::Digit->new(basis_tick => $basis_tick, supplied_barrier => 10) } qr/1 digit/,
        'Multi-digit barriers are not permitted.';
    throws_ok { BOM::Product::Contract::Strike::Digit->new(basis_tick => $basis_tick, supplied_barrier => 'P') } qr/1 digit/,
        'Nor non-digit characters.';

};

subtest 'some digits' => sub {
    my $test_symbol = 'frxUSDJPY';
    my $basis_tick  = BOM::Market::Data::Tick->new(
        epoch  => time,
        quote  => 100,
        symbol => $test_symbol,
    );

    foreach my $barrier_string (0 .. 9) {
        my $strike = new_ok(
            'BOM::Product::Contract::Strike::Digit',
            [{
                    basis_tick       => $basis_tick,
                    supplied_barrier => $barrier_string,
                }
            ],
            $barrier_string
        );

        is($strike->supplied_type,  'digit',         ' properly recognized as digit');
        is($strike->as_relative,    $barrier_string, '  as_relative is same');
        is($strike->as_difference,  $barrier_string, '  as_difference is same');
        is($strike->as_absolute,    $barrier_string, '  as_absolute is same');
        is($strike->pip_difference, $barrier_string, '  pip_difference is same');
    }

};

1;
