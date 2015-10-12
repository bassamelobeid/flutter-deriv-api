package BOM::MarketData::ImpliedRate;

use Moose;
extends 'BOM::MarketData::Rates';

has _data_location => (
    is      => 'ro',
    default => 'interest_rates',
);

around _document_content => sub {
    my $orig = shift;
    my $self = shift;

    my @symbols = split '-', $self->symbol;

    return {
        %{$self->$orig},
        rates => $self->rates,
        type  => $self->type,
        info  => $symbols[0] . ' rates implied from ' . $symbols[1],
    };
};

with 'BOM::MarketData::Role::VersionedSymbolData';

has type => (
    is      => 'ro',
    isa     => 'bom_interest_rate_type',
    default => 'implied',
);

no Moose;
__PACKAGE__->meta->make_immutable;
1;
