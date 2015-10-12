package BOM::MarketData::VolSurface::Utils;

=head1 NAME

BOM::MarketData::VolSurface::Utils

=head1 DESCRIPTION

Some general vol-related utility functions.

=head1 SYNOPSIS

  my $utils = BOM::MarketData::VolSurface::Utils->new;
  my $cutoff = $utils->default_bloomberg_cutoff($underlying);

=cut

use Moose;

use DateTime::TimeZone;
use Memoize;

use Date::Utility;

=head1 METHODS

=head2 default_bloomberg_cutoff

The cutoff we copy from Bloomberg into our vol
files for a given underlying.

=cut

sub default_bloomberg_cutoff {
    my ($self, $underlying) = @_;
    my $when   = $underlying->exchange->representative_trading_date;
    my $market = $underlying->market;

    # Commodities don't really have a concept of cutoff, and we don't cut
    # surfaces when pricing commodity bets (making the fact that it has a
    # cut irrelevant), but we need to set something as the cutoff, and in
    # my mind NY1000 makes the most sense.
    my $cutoff = ($market->vol_cut_off eq 'NY1000') ? 'New York 10:00' : $self->default_pricing_cutoff($underlying);
    return $cutoff;
}

# The cutoff we (should) use for pricing our bets,
# given our chosen expiry times.
sub default_pricing_cutoff {
    my ($self, $underlying) = @_;
    my $when     = $underlying->exchange->representative_trading_date;
    my $exchange = $underlying->exchange;

    # representative_trading_date doesn't cover DST.
    # But this is just a default, so it should be ok.
    return 'UTC ' . $exchange->closing_on($when)->time_hhmm;
}

=head2 NY1700_rollover_date_on

Returns (as a Date::Utility) the NY1700 rollover date for a given Date::Utility.

=cut

sub NY1700_rollover_date_on {
    my ($self, $date) = @_;

    return $date->truncate_to_day->plus_time_interval((17 - $date->timezone_offset('America/New_York')->hours) * 3600);
}

=head2 effective_date_for

Get the "effective date" for a given Date::Utility (stated in GMT).

This is the we should consider a volsurface effective for, and rolls over
every day at NY1700. If a volsurface is quoted at GMT2300, its effective
date is actually the next day.

This returns a Date::Utility truncated to midnight of the relevant day.

=cut

sub effective_date_for {
    my ($self, $date) = @_;

    return $date->plus_time_interval((7 + $date->timezone_offset('America/New_York')->hours) * 3600)->truncate_to_day;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
