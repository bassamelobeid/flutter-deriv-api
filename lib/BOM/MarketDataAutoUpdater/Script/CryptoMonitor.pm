package BOM::MarketDataAutoUpdater::Script::CryptoMonitor;
use Moose;
with 'App::Base::Script';

use BOM::MarketDataAutoUpdater::CryptoMonitor;

sub documentation {
    return 'Monitor crypto OHLC we have received from Bloomberg.';
}

sub options {
    return [{
            name          => 'action',
            documentation => 'monitor crypto ohlc',
            option_type   => 'string',
            default       => 'monitor',
        },
    ];
}

sub script_run {
    my $self = shift;

    my $action = $self->getOption('action');

    if ($action eq 'monitor') {
        BOM::MarketDataAutoUpdater::CryptoMonitor->new->run;
    }

    return $self->return_value();
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
