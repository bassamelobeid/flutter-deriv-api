package BOM::MarketData::Fetcher::EconomicEvent;

=head1 NAME

BOM::MarketData::Fetcher::EconomicEvent

=cut

=head1 DESCRIPTION

Responsible to fetch events from EconomicEventCalendar

=cut

use Carp;
use Moose;
use BOM::MarketData::EconomicEventCalendar;

sub get_latest_events_for_period {
    my ($self, $period) = @_;

    my $start  = $period->{from};
    my $end    = $period->{to};
    my $ee_cal = BOM::MarketData::EconomicEventCalendar->new({for_date => $start});

    return $ee_cal->get_latest_events_for_period($period);
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
