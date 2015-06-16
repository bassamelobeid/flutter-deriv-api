#!/usr/bin/env perl

use Test::Most (tests => 4);
use Test::FailWarnings;

use BOM::Market::Data::Tick;
use BOM::Product::Contract::Strike;

subtest 'construction' => sub {
    my $test_symbol = 'frxUSDJPY';
    my $basis_tick  = BOM::Market::Data::Tick->new(
        epoch  => time,
        quote  => 100,
        symbol => $test_symbol,
    );

    my $strike = new_ok(
        'BOM::Product::Contract::Strike',
        [{
                basis_tick       => $basis_tick,
                supplied_barrier => 'S0P'
            }
        ],
        'Seemingly normal'
    );

    is($strike->underlying->symbol, $test_symbol, 'Underlying is populated with symbol from basis tick if left off');

    $strike = new_ok(
        'BOM::Product::Contract::Strike',
        [{
                underlying       => 'R_100',
                basis_tick       => $basis_tick,
                supplied_barrier => 'S0P'
            }
        ],
        'Mismatched underlying'
    );
    is($strike->underlying->symbol, 'R_100', 'Underlying supplied is different than basis tick does not blow up and uses given value.');

};

subtest 'ATM representation' => sub {
    my $test_symbol = 'frxUSDJPY';
    my $basis_tick  = BOM::Market::Data::Tick->new(
        epoch  => time,
        quote  => 100,
        symbol => $test_symbol,
    );

    my %supplied_barriers = (
        relative   => 'S0P',
        absolute   => '100',
        difference => '+0'
    );
    foreach my $atm_string (values %supplied_barriers) {
        my $strike = new_ok(
            'BOM::Product::Contract::Strike',
            [{
                    basis_tick       => $basis_tick,
                    supplied_barrier => $atm_string,
                }
            ],
            $atm_string
        );

        is($strike->supplied_barrier, $supplied_barriers{$strike->supplied_type}, ' properly recognized as ' . $strike->supplied_type);
        is($strike->as_relative,      'S0P',                                      '  ATM as_relative is S0P');
        is($strike->as_difference,    '+0.000',                                   '  ATM as_difference is +0.000');
        is($strike->as_absolute,      '100.000',                                  '  ATM as_absolute is 100.000');
        is($strike->pip_difference,   '0',                                        '  ATM pip_difference is 0');
    }

};

subtest 'up barrier representation' => sub {
    my $test_symbol = 'R_100';
    my $basis_tick  = BOM::Market::Data::Tick->new(
        epoch  => time,
        quote  => 20000,
        symbol => $test_symbol,
    );

    my %supplied_barriers = (
        relative   => 'S1000P',
        absolute   => '20010',
        difference => '+10'
    );
    foreach my $non_atm_string (values %supplied_barriers) {
        my $strike = new_ok(
            'BOM::Product::Contract::Strike',
            [{
                    basis_tick       => $basis_tick,
                    supplied_barrier => $non_atm_string,
                }
            ],
            $non_atm_string
        );

        is($strike->supplied_barrier, $supplied_barriers{$strike->supplied_type}, ' properly recognized as ' . $strike->supplied_type);
        is($strike->as_relative,      'S1000P',                                   '  up as_relative is S0P');
        is($strike->as_difference,    '+10.00',                                   '  up as_difference is +0.000');
        is($strike->as_absolute,      '20010.00',                                 '  up as_absolute is 100.000');
        is($strike->pip_difference,   '1000',                                     '  up pip_difference is 0');
    }

};

subtest 'down barrier representation' => sub {
    my $test_symbol = 'R_50';
    my $basis_tick  = BOM::Market::Data::Tick->new(
        epoch  => time,
        quote  => 3000,
        symbol => $test_symbol,
    );

    my %supplied_barriers = (
        relative   => 'S-5P',
        absolute   => '2999.9995',
        difference => '-0.0005'
    );
    foreach my $non_atm_string (values %supplied_barriers) {
        my $strike = new_ok(
            'BOM::Product::Contract::Strike',
            [{
                    basis_tick       => $basis_tick,
                    supplied_barrier => $non_atm_string,
                }
            ],
            $non_atm_string
        );

        is($strike->supplied_barrier, $supplied_barriers{$strike->supplied_type}, ' properly recognized as ' . $strike->supplied_type);
        is($strike->as_relative,      'S-5P',                                     '  down as_relative is S-5P');
        is($strike->as_difference,    '-0.0005',                                  '  down as_difference is -0.0005');
        is($strike->as_absolute,      '2999.9995',                                '  down as_absolute is 2999.9995');
        is($strike->pip_difference,   '-5',                                       '  down pip_difference is -5');
    }

};

1;
