package BOM::Market::Markups;

use Moose;

=head1 NAME

BOM::Market::Markups

=head1 DESCRIPTION

Used in conjunction with I<BOM::Market>, to represent ll the markups that can be applied to the market.

=head1 ATTRIBUTES

=head2 digital_spread

A hash of the digital spread markup.
{
    european => ...
    single_barrier => ...
    double_barrier => ...
}

=cut

has 'digital_spread' => (
    is => 'ro',
);

=head2 market

Should we apply market specific markups like news_corrections.

=cut

has 'apply_traded_markets_markup' => (
    is  => 'ro',
    isa => 'Bool',
);

=head2 butterfly

Should we apply butterfly markups.

=cut

has 'apply_butterfly_markup' => (
    is  => 'ro',
    isa => 'Bool',
);

no Moose;
__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Arun Murali, C<< <arun at regentmarkets.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2013 RMG Technology (M) Sdn Bhd

=cut
