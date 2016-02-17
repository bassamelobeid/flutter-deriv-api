package BOM::MarketData::ImpliedRate;

use BOM::System::Chronicle;
use Data::Chronicle::Reader;
use Data::Chronicle::Writer;

=head1 NAME

BOM::MarketData::ImpliedRate - A module to save/load implied interest rates for currencies

=head1 DESCRIPTION

This module saves/loads implied interest rate data to/from Chronicle. 

my $ir_data = BOM::MarketData::ImpliedRate->new(symbol => 'USD-EUR',
        rates => { 7 => 0.5, 30 => 1.2, 90 => 2.4 });
 $ir_data->save;

To read implied interest rates for a currency:

 my $ir_data = BOM::MarketData::ImpliedRate->new(symbol => 'USD-EUR');

 my $rates = $ir_data->rates;

=cut

use Moose;
extends 'BOM::MarketData::Rates';

=head2 for_date

The date for which we wish data

=cut

has for_date => (
    is      => 'ro',
    isa     => 'Maybe[Date::Utility]',
    default => undef,
);

has chronicle_reader => (
    is      => 'ro',
    isa     => 'Data::Chronicle::Reader',
    default => sub { BOM::System::Chronicle::get_chronicle_reader() },
);

has chronicle_writer => (
    is      => 'ro',
    isa     => 'Data::Chronicle::Writer',
    default => sub { BOM::System::Chronicle::get_chronicle_writer() },
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

=head2 document

The CouchDB document that this object is tied to.

=cut

has document => (
    is         => 'rw',
    lazy_build => 1,
);

sub _build_document {
    my $self = shift;

    my $document = $self->chronicle_reader->get('interest_rates', $self->symbol);

    if ($self->for_date and $self->for_date->datetime_iso8601 lt $document->{date}) {
        $document = $self->chronicle_reader->get_for('interest_rates', $self->symbol, $self->for_date->epoch);

        # This works around a problem with Volatility surfaces and negative dates to expiry.
        # We have to use the oldest available surface.. and we don't really know when it
        # was relative to where we are now.. so just say it's from the requested day.
        # We do not allow saving of historical surfaces, so this should be fine.
        $document //= {};
        $document->{date} = $self->for_date->datetime_iso8601;
    }

    return $document;
}

sub save {
    my $self = shift;

    if (not defined $self->chronicle_reader->get('interest_rates', $self->symbol)) {
        $self->chronicle_writer->set('interest_rates', $self->symbol, {});
    }

    return $self->chronicle_writer->set('interest_rates', $self->symbol, $self->_document_content);
}

has type => (
    is      => 'ro',
    isa     => 'bom_interest_rate_type',
    default => 'implied',
);

no Moose;
__PACKAGE__->meta->make_immutable;
1;
