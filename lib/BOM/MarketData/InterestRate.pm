package BOM::MarketData::InterestRate;

=head1 NAME

BOM::MarketData::InterestRate

=head1 DESCRIPTION

=cut

use Moose;
extends 'BOM::MarketData::Rates';

use Math::Function::Interpolator;

has '_data_location' => (
    is      => 'ro',
    default => 'interest_rates',
);

around _document_content => sub {
    my $orig = shift;
    my $self = shift;

    return {
        %{$self->$orig},
        type  => $self->type,
        rates => $self->rates
    };
};

with 'BOM::MarketData::Role::VersionedSymbolData';

has type => (
    is      => 'ro',
    isa     => 'bom_interest_rate_type',
    default => 'market',
);

no Moose;
__PACKAGE__->meta->make_immutable;
1;
