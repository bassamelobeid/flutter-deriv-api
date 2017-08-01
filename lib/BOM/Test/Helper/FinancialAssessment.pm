package BOM::Test::Helper::FinancialAssessment;

use warnings;
use strict;

use BOM::Platform::Account::Real::default;

sub _get_by_index {
    my $h = shift;
    return (sort { $h->{$a} <=> $h->{$b} || $a cmp $b } keys %$h)[shift];

}
my $first = sub {
    return (sort keys %{$_[0]})[0];
};
my $min = sub { return _get_by_index($_[0], 0) };
my $max = sub { return _get_by_index($_[0], -1) };
my $types = {
    'first' => $first,
    'min'   => $min,
    'max'   => $max,
};

=head2 get_fulfilled_hash

    returns hash of all questions inside financial assesements with answers.
    Answer selection is controlled by optional argument:
    - first (default) - first from sorted list of names
    - min - element with minimum weight, first from sorted list
    - max - element with maximum weight, last in sorted list

=cut

sub get_fulfilled_hash {
    my $type = shift // 'first';
    die "Types can be: ", join ', ', (keys %$types) unless defined $types->{$type};
    return _get_with_selector($types->{$type});
}

sub _get_with_selector {
    my $func = shift;
    my $h    = BOM::Platform::Account::Real::default::get_financial_input_mapping();
    my %r    = map { $_ => $func->($h->{$_}->{possible_answer}) } keys %$h;
    return \%r;
}

1;
