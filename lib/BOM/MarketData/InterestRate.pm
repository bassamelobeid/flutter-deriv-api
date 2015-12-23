package BOM::MarketData::InterestRate;

use BOM::System::Chronicle;

=head1 NAME

BOM::MarketData::InterestRate - A module to save/load interest rates for currencies

=head1 DESCRIPTION

This module saves/loads interest rate data to/from Chronicle. 

my $ir_data = BOM::MarketData::InterestRate->new(symbol => 'USD',
        rates => { 7 => 0.5, 30 => 1.2, 90 => 2.4 });
 $ir_data->save;

To read interest rates for a currency:

 my $ir_data = BOM::MarketData::InterestRate->new(symbol => 'USD');

 my $rates = $ir_data->rates;

=cut

use Moose;
extends 'BOM::MarketData::Rates';

use Math::Function::Interpolator;

=head2 for_date

The date for which we wish data

=cut

has for_date => (
    is      => 'ro',
    isa     => 'Maybe[Date::Utility]',
    default => undef,
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

=head2 document

The CouchDB document that this object is tied to.

=cut

has document => (
    is         => 'rw',
    lazy_build => 1,
);

sub _build_document {
    my $self = shift;

    my $document = BOM::System::Chronicle::get('interest_rates', $self->symbol);

    if ($self->for_date and $self->for_date->datetime_iso8601 lt $document->{date}) {
        $document = BOM::System::Chronicle::get_for('interest_rates', $self->symbol, $self->for_date->epoch);
        $document //= {};
    }

    return $document;
}

sub save {
    my $self = shift;

    if (not defined BOM::System::Chronicle::get('interest_rates', $self->symbol)) {
        BOM::System::Chronicle::set('interest_rates', $self->symbol, {}, $self->recorded_date);
    }

    return BOM::System::Chronicle::set('interest_rates', $self->symbol, $self->_document_content, $self->recorded_date);
}

has type => (
    is      => 'ro',
    isa     => 'bom_interest_rate_type',
    default => 'market',
);

no Moose;
__PACKAGE__->meta->make_immutable;
1;
