package BOM::MarketDataAutoUpdater::Script::UpdateVol;

=head1 NAME

BOM::MarketDataAutoUpdater::Script::UpdateVol;

=head1 DESCRIPTION

Updates our vols with the latest quotes we have received from Bloomberg.

=cut

use Moose;
with 'App::Base::Script';

use BOM::MarketDataAutoUpdater::Forex;
use BOM::MarketDataAutoUpdater::Indices;
use BOM::MarketDataAutoUpdater::Flat;

sub documentation {
    return 'updates volatility surfaces.';
}

sub script_run {
    my $self = shift;

    # su nobody
    unless ($>) {
        local $) = (getgrnam('nogroup'))[2];
        local $> = (getpwnam('nobody'))[2];
    }
    my $opt1 = shift @ARGV || '';

    local $SIG{ALRM} = sub { die 'Timed out.' };
    alarm(60 * 30);

    my ($class, $filename);
    if ($opt1 eq 'forex') {
        $class    = 'BOM::MarketDataAutoUpdater::Forex';
        $filename = '';
    } elsif ($opt1 eq 'indices') {
        $class    = 'BOM::MarketDataAutoUpdater::Indices';
        $filename = '/feed/sd/raw_data/auto_upload.xls';
    } elsif ($opt1 eq 'flat') {
        $class    = 'BOM::MarketDataAutoUpdater::Flat';
        $filename = '';
    } else {
        die "unrecognized request $opt1";
    }

    my $market = $opt1;

    $class->new(
        filename     => $filename,
        input_market => $market,
    )->run;

    return $self->return_value();
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
