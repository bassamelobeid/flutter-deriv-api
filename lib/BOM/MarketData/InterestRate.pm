package BOM::MarketData::InterestRate;

use BOM::System::Chronicle;

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

=head2 VersionedSymbolData

As this module inherits from VersionedSymbolData we need to manipulate the inheritance so that we can "inject"
our Chronicle saving code in the inherited "save" subroutine.

=cut

with 'BOM::MarketData::Role::VersionedSymbolData' => {
    -alias    => {save => '_save'},
    -excludes => ['save']};

sub save {
    my $self = shift;

    #first call original save method to save all data into CouchDB just like before
    my $result = $self->_save();

    BOM::System::Chronicle::set('interest_rates', $self->symbol, $self->_document_content);
    return $result;
}

has type => (
    is      => 'ro',
    isa     => 'bom_interest_rate_type',
    default => 'market',
);

no Moose;
__PACKAGE__->meta->make_immutable;
1;
