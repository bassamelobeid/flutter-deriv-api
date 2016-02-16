package BOM::MarketData::Dividend;

=head1 NAME

BOM::MarketData::Dividend - A module to save/load dividends 

=head1 DESCRIPTION

This module saves/loads dividends data to/from Chronicle. 
To save dividends for a company:

my $corp_dividends = BOM::MarketData::Dividends->new(symbol => $symbol,
        rates => { 1 => 0, 2 => 1, 3=> 0.04 }
        discrete_points => { '2015-04-24' => 0, '2015-09-09' => 0.134 });
 $corp_dividends->save;

To read dividends information for a company:

 my $corp_dividends = BOM::MarketData::Dividends->new(symbol => $symbol);

 my $rates = $corp_dividends->rates;
 my $disc_points = $corp_dividends->discrete_points;

=cut

use Moose;
extends 'BOM::MarketData::Rates';

use BOM::System::Chronicle;
use Data::Chronicle::Reader;
use Data::Chronicle::Writer;

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

=head2 symbol

Represents underlying symbol

=cut

has document => (
    is         => 'rw',
    lazy_build => 1,
);

sub _build_document {
    my $self = shift;

    my $document = $self->chronicle_reader->get('dividends', $self->symbol);

    if ($self->for_date and $self->for_date->datetime_iso8601 lt $document->{date}) {
        $document = $self->chronicle_reader->get_for('dividends', $self->symbol, $self->for_date->epoch);

        # This works around a problem with Volatility surfaces and negative dates to expiry.
        # We have to use the oldest available surface.. and we don't really know when it
        # was relative to where we are now.. so just say it's from the requested day.
        # We do not allow saving of historical surfaces, so this should be fine.
        $document //= {};
        $document->{date} = $self->for_date->datetime_iso8601;
    }

    return $document;
}
around _document_content => sub {
    my $orig = shift;
    my $self = shift;

    return {
        %{$self->$orig},
        rates           => $self->rates,
        discrete_points => $self->discrete_points,
        date            => $self->recorded_date->datetime_iso8601,
    };
};

sub save {
    my $self = shift;

    #if chronicle does not have this document, first create it because in document_content we will need it
    if (not defined $self->chronicle_reader->get('dividends', $self->symbol)) {
        $self->chronicle_writer->set('dividends', $self->symbol, {});
    }

    return $self->chronicle_writer->set('dividends', $self->symbol, $self->_document_content, $self->recorded_date);
}

=head2 recorded_date

The date (and time) that the dividend  was recorded, as a Date::Utility.

=cut

has recorded_date => (
    is         => 'ro',
    isa        => 'Date::Utility',
    lazy_build => 1,
);

sub _build_recorded_date {
    my $self = shift;
    return Date::Utility->new($self->document->{date});
}

=head2 discrete_points

The discrete dividend points received from provider.

=cut

has discrete_points => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_discrete_points {
    my $self = shift;

    return if not defined $self->document;
    return $self->document->{discrete_points} || undef;
}

=head2 rate_for

Returns the rate for a particular timeinyears for symbol.
->rate_for(7/365)

=cut

sub rate_for {
    my ($self, $tiy) = @_;

    # Handle discrete dividend
    my ($nearest_yield_days_before, $nearest_yield_before) = (0, 0);
    my $days_to_expiry = $tiy * 365.0;
    my @sorted_expiries = sort { $a <=> $b } keys(%{$self->rates});
    foreach my $day (@sorted_expiries) {
        if ($day <= $days_to_expiry) {
            $nearest_yield_days_before = $day;
            $nearest_yield_before      = $self->rates->{$day};
            next;
        }
        last;
    }

    # Re-annualize
    my $discrete_points = $nearest_yield_before * $nearest_yield_days_before / 365;

    if ($days_to_expiry) {
        return $discrete_points * 365 / ($days_to_expiry * 100);
    }
    return 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
