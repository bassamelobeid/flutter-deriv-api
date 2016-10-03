#!/etc/rmg/bin/perl
package BOM::MarketDataAutoUpdater::UpdateVol;

=head1 NAME

BOM::System::Script::UpdateVol;

=head1 DESCRIPTION

Updates our vols with the latest quotes we have received from Bloomberg.

=cut

use Moose;
with 'App::Base::Script';

use BOM::MarketDataAutoUpdater::Forex;
use BOM::MarketDataAutoUpdater::Indices;

# su nobody
unless ($>) {
    $) = (getgrnam('nogroup'))[2];
    $> = (getpwnam('nobody'))[2];
}
my $opt1 = shift || '';

$SIG{ALRM} = sub { die 'Timed out.' };
alarm(60 * 30);

sub documentation {
    return 'updates volatility surfaces.';
}
sub script_run {
    my $self = shift;
    my $class = $opt1 =~ /(indices|stocks)/ ? 'BOM::MarketDataAutoUpdater::Indices' : 'BOM::MarketDataAutoUpdater::Forex';
    my $filename = $opt1 =~  /indices/ ? 'auto_upload.xls' : 'auto_upload_Euronext.xls';
    my $market = $opt1 !~ /(indices|stocks)/ ? 'forex' : ($opt1 =~ /indices/ ? 'indices' : 'stocks') ;
    $class->new(
        filename       => $filename,
        input_market   => $market,
    )->run;
    return $self->return_value();
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
package main;
exit BOM::MarketDataAutoUpdater::UpdateVol->new->run;

