#!/usr/bin/perl
package BOM::System::Script::UpdateVol;

=head1 NAME

BOM::System::Script::UpdateVol;

=head1 DESCRIPTION

Updates our vols with the latest quotes we have received from Bloomberg.

=cut

use Moose;
with 'App::Base::Script';
with 'BOM::Utility::Logging';
use lib qw( /home/git/bom/cgi );

use File::Find::Rule;

use BOM::Platform::Email qw(send_email);
use BOM::Platform::Runtime;
use BOM::MarketData::AutoUpdater::Forex;
use BOM::MarketData::AutoUpdater::Indices;

BOM::Utility::Log4perl::init_log4perl_console;

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
    die 'Script only to run on master servers.'
    unless BOM::Platform::Runtime->instance->hosts->localhost->has_role('master_live_server');
    my $class = $opt1 =~ /(indices|stocks)/ ? 'BOM::MarketData::AutoUpdater::Indices' : 'BOM::MarketData::AutoUpdater::Forex';
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
exit BOM::System::Script::UpdateVol->new->run;

