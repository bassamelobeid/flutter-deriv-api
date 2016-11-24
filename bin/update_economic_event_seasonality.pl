#!/etc/rmg/bin/perl
package BOM::MarketDataAutoUpdater::UpdateEconomicEventSeasonality;

=head1 NAME

BOM::MarketDataAutoUpdater::UpdateEconomicEventSeasonality;

=head1 DESCRIPTION

Updates seasonality on economic events retrieved from Forex Factory.

=cut

use Moose;
with 'App::Base::Script';

use Quant::Framework::Seasonality;
use BOM::System::Chronicle;
use BOM::MarketData qw(create_underlying_db);

# su nobody
unless ($>) {
    $) = (getgrnam('nogroup'))[2];
    $> = (getpwnam('nobody'))[2];
}
my $opt1 = shift || '';

$SIG{ALRM} = sub { die 'Timed out.' };
alarm(60 * 30);

sub documentation {
    return 'updates seasonality at 00:15:00 GMT every day.';
}

sub script_run {
    my $self = shift;

    # currently, it is only needed for intraday engine.
    my @underlying_symbols = create_underlying_db->symbols_for_intraday_fx();
    my $qfs                = Quant::Framework::Seasonality->new(
        chronicle_reader => BOM::System::Chronicle::get_chronicle_reader,
        chronicle_writer => BOM::System::Chronicle::get_chronicle_writer
    );

    foreach my $symbol (@underlying_symbols) {
        $qfs->generate_economic_event_seasonality({underlying_symbol => $symbol});
    }

    return $self->return_value();
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

package main;
exit BOM::MarketDataAutoUpdater::UpdateEconomicEventSeasonality->new->run;

