package BOM::MarketDataAutoUpdater::Script::UpdateEconomicEvents;

use Moose;
with 'App::Base::Script';
use BOM::MarketDataAutoUpdater::UpdateEconomicEvents;

sub documentation { return 'This script runs economic events update from forex factory and Bloomberg at 00:15 GMT'; }

sub script_run {
    my $self = shift;

    BOM::MarketDataAutoUpdater::UpdateEconomicEvents->new->run;
    return $self->return_value();

}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
