#!/etc/rmg/bin/perl

use Test::Most (tests => 3);
use Test::Warnings;

use Postgres::FeedDB::Spot::Tick;
use BOM::Product::Contract::Strike::Digit;

subtest 'construction' => sub {
    my $test_symbol = 'frxUSDJPY';
    my $basis_tick  = Postgres::FeedDB::Spot::Tick->new(
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

    lives_ok {
        my $strike = BOM::Product::Contract::Strike::Digit->new(
            basis_tick       => $basis_tick,
            supplied_barrier => 10
        );
        ok !$strike->confirm_validity, 'not a valid barrier';
        like($strike->primary_validation_error->{message}, qr/invalid supplied barrier format for digits/, 'throws error');
    }
    'multi-digit barrier';
    lives_ok {
        my $strike = BOM::Product::Contract::Strike::Digit->new(
            basis_tick       => $basis_tick,
            supplied_barrier => 'P'
        );
        ok !$strike->confirm_validity, 'not a valid barrier';
        like($strike->primary_validation_error->{message}, qr/invalid supplied barrier format for digits/, 'throws error');
    }
    'non digit barrier';

};

subtest 'some digits' => sub {
    my $test_symbol = 'frxUSDJPY';
    my $basis_tick  = Postgres::FeedDB::Spot::Tick->new(
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
