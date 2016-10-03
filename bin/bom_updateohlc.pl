#!/etc/rmg/bin/perl
package BOM::MarketDataAutoUpdater::UpdateOhlc;

use Moose;
with 'App::Base::Script';

use BOM::MarketDataAutoUpdater::OHLC;
sub documentation {
    return 'Updates ohlc we have received from Bloomberg.';
}

sub options {
    return [{
             name          => 'action',
             documentation => 'update or verify ohlc',
             option_type   => 'string',
             default       => 'update',
        },
    ];
}

sub script_run {
    my $self = shift;

    my $action  = $self->getOption('action');

    if ($action eq 'update') {
         BOM::MarketDataAutoUpdater::OHLC->new->run;
    } elsif ($action eq 'verify') {
         BOM::MarketDataAutoUpdater::OHLC->new->verify_ohlc_update;
    }

    return $self->return_value();
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
package main;
exit BOM::MarketDataAutoUpdater::UpdateOhlc->new->run;
