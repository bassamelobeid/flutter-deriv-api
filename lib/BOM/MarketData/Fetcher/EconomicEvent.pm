package BOM::MarketData::Fetcher::EconomicEvent;

=head1 NAME

BOM::MarketData::Fetcher::EconomicEvent

=cut

=head1 DESCRIPTION

Responsible to fetch or create events on Chronicle

=cut

use Carp;
use Moose;
use BOM::MarketData::EconomicEventCalendar;

sub get_latest_events_for_period {
    my ($self, $period) = @_;
    return BOM::MarketData::EconomicEventCalendar->new->get_latest_events_for_period($period);
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
