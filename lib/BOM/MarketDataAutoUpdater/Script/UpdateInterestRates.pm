package BOM::MarketDataAutoUpdater::Script::UpdateInterestRates;

use Moose;
with 'App::Base::Script';

use BOM::MarketDataAutoUpdater::InterestRates;

sub documentation { return 'This is a cron that updates interest rates info from Bloomberg to Chronicle.'; }

sub script_run {
    my $self = shift;
    BOM::MarketDataAutoUpdater::InterestRates->new->run;
    return $self->return_value();
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
