package BOM::MarketData::ImpliedRate;

use BOM::System::Chronicle;

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

    my $document = BOM::System::Chronicle::get('interest_rates', $self->symbol);

    if ($self->for_date and $self->for_date->datetime_iso8601 lt $document->{date}) {
        $document = BOM::System::Chronicle::get_for('interest_rates', $self->symbol, $self->for_date->epoch);

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

    if (not defined BOM::System::Chronicle::get('interest_rates', $self->symbol)) {
        BOM::System::Chronicle::set('interest_rates', $self->symbol, {});
    }

    return BOM::System::Chronicle::set('interest_rates', $self->symbol, $self->_document_content);
}


has type => (
    is      => 'ro',
    isa     => 'bom_interest_rate_type',
    default => 'implied',
);

no Moose;
__PACKAGE__->meta->make_immutable;
1;
