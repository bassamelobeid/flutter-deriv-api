package BOM::Rules::Comparator::Text;

=head1 NAME

BOM::Rules::Comparator::Text

=head1 DESCRIPTION

This class contains all text-based comparison operations

=cut

use strict;
use warnings;

use List::Util qw( any );
use Text::Unidecode;

=head2 check_words_similarity

This sub determines whether each word of C<$expected>
is in C<$actual> value (word by word comparison).

It takes the following arguments:

=over 4

=item * C<$actual> - the actual words.

=item * C<$expected> - the expected words.

=back

Returns 1 if similar, 0 otherwise.

=cut

sub check_words_similarity {
    my ($actual, $expected) = @_;

    my @actuals      = split ' ', lc unidecode($actual)   || return 0;
    my @expectations = split ' ', lc unidecode($expected) || return 0;

    for my $actual_value (@actuals) {
        return 0 unless any { $actual_value eq $_ } @expectations;
    }

    return 1;
}

1;
