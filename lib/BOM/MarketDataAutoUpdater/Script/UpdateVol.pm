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
use Getopt::Long qw(GetOptions :config no_auto_abbrev no_ignore_case);

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

    my $opt        = shift @ARGV || '';    #update operation. Accepts [forex|indices|flat]
    my $source     = shift @ARGV || '';    #data source. Accepts [BBDL|BVOL]
    my $root_path  = shift @ARGV || '';    #the root path of the source of data
    my $update_for = shift @ARGV || '';    #update option. Accepts [forex|indices|all|quanto

    local $SIG{ALRM} = sub { die 'Timed out.' };

    alarm(60 * 30);

    my ($class);
    if ($opt eq 'forex') {
        $class = 'BOM::MarketDataAutoUpdater::Forex';
    } elsif ($opt eq 'indices') {
        $class = 'BOM::MarketDataAutoUpdater::Indices';
    } elsif ($opt eq 'flat') {
        $class = 'BOM::MarketDataAutoUpdater::Flat';
    } else {
        die "unrecognized request $opt";
    }

    my $market = $opt;
    $update_for ||= $opt;

    $class->new(
        source       => $source,
        input_market => $market,
        root_path    => $root_path,
        update_for   => $update_for,
    )->run;

    return $self->return_value();
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
