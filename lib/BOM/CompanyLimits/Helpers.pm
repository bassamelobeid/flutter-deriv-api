package BOM::CompanyLimits::Helpers;
use strict;
use warnings;

use Data::Dumper;

sub get_all_key_combinations {
    my (@a, $delim) = @_;
    $delim ||= ',';

    my @combinations;
    foreach my $i (1 .. (1 << scalar @a) - 1) {
        my $combination;
        foreach my $j (0 .. scalar @a - 1) {
            my $k = (1 << $j);
            my $c = (($i & $k) == $k) ? $a[$j] : '';
            $combination = ($j == 0 ? "$c" : "$combination$delim$c");
        }
        push @combinations, $combination;
    }

    return @combinations;
}

1;
