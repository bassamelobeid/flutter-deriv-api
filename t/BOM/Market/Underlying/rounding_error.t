use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Warnings;
use BOM::MarketData qw(create_underlying);

# pipsize = 0.001
my $underlying_symbol = create_underlying('R_10');
my $pip_size          = $underlying_symbol->{pip_size};

# Ensure pipsized_value is rounding accurately when there is floating point error
# E.g for R_10, $underlying_symbol->pipsized_value(150.9065) = 150.907

subtest 'floating point error' => sub {

    my $raw_value = 101;

    my $expected_value;
    my $rounding_value;
    my $counter = 1;

    for my $i (1 .. 100) {

        $raw_value += $i * 10.5 * $pip_size;
        $rounding_value = $underlying_symbol->pipsized_value($raw_value) + 0;

        $expected_value = $raw_value + 0.5 * $pip_size * ($counter % 2);
        $counter += 0.5;

        is $rounding_value , $expected_value, 'Raw value : ' . $raw_value . ' , Expected value : ' . $expected_value . ' , Got : ' . $rounding_value;

    }
};

done_testing();
