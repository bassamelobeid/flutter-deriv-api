package BOM::Test::Helpers::FinancialAssessment;

use warnings;
use strict;

use BOM::Platform::Account::Real::default;

=head2 get_fulfilled_hash

    returns hash of all questions inside financial assesements with answers. Answers are selected by getting first in sorted list.

=cut

sub get_fulfilled_hash {
    my $h = BOM::Platform::Account::Real::default::get_financial_input_mapping();
    my %r = map { $_ => (sort keys %{$h->{$_}->{possible_answer}})[0] } keys %$h;
    return \%r;
}

1;

