package BOM::MarketData::Dividend;

=head1 NAME

BOM::MarketData::Dividend

=head1 DESCRIPTION

=cut

use Moose;
extends 'BOM::MarketData::Rates';

has '_data_location' => (
    is      => 'ro',
    default => 'dividends',
);

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

with 'BOM::MarketData::Role::VersionedSymbolData';

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
