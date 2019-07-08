package BOM::CompanyLimits::Helpers;
use strict;
use warnings;

sub get_all_key_combinations {
    my (@a) = @_;

    my @combinations;
    foreach my $i (1 .. (1 << (scalar @a))) {
        my $combination = '';
        foreach my $j (1 .. (scalar @a)) {
            my $k = ($j << $j);
            my $c = (($i & $k) == $k) ? $a[$j - 1] : '';
            $combination = "$combination,$c";
        }
        push @combinations, $combination;
    }

    return @combinations;
}
