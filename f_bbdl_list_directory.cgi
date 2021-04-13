#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use CGI;

use f_brokerincludeall;

use BOM::Config;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use Bloomberg::FileDownloader;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();
use BOM::Config::Runtime;
PrintContentType();
BrokerPresentation('BBDL LIST DIRECTORY');

my $cgi    = CGI->new;
my $broker = $cgi->param('broker');

my $bbdl = Bloomberg::FileDownloader->new();

Bar("BBDL Directory Listing");
#don't allow from devserver, to avoid uploading wrong files
if (not BOM::Config::on_production()) {
    print "<p class='error'>Sorry, you cannot connect to Bloomberg's ftp from a development server. Please use a live server.</p>";
    code_exit_BO();
}

my $sftp = $bbdl->login;
my $ls   = $sftp->ls('/') or die "unable to change cwd: " . $sftp->error;

my @request_files  = grep { $_->{'filename'} =~ /\.req/ } @{$ls};
my @response_files = grep { $_->{'filename'} =~ /\.csv\.enc/ } @{$ls};

my @request_list  = map { _retrieve_table_data($_, $broker) } @request_files;
my @response_list = map { _retrieve_table_data($_, $broker) } @response_files;

if (@request_list) {
    my $request_f;
    BOM::Backoffice::Request::template()->process(
        'backoffice/bbdl/list_directory.html.tt',
        {
            file_type => 'REQUEST FILES',
            args      => \@request_list
        },
        \$request_f
    ) || die BOM::Backoffice::Request::template()->error(), "\n";

    print $request_f;
    print "</br></br>";
}

if (@response_list) {
    my $response_f;

    BOM::Backoffice::Request::template()->process(
        'backoffice/bbdl/list_directory.html.tt',
        {
            file_type => 'RESPONSE FILES',
            args      => \@response_list
        },
        $response_f
    ) || die BOM::Backoffice::Request::template()->error(), "\n";

    print $response_f;
}

sub _retrieve_table_data {
    my ($rf, $current_broker) = @_;

    my $mdtm            = $rf->{"a"}->mtime;
    my $bom_mdtm        = Date::Utility->new($mdtm);
    my $how_long_ago    = time - $bom_mdtm->epoch;
    my $more_than_a_day = (time > $mdtm + 86400) ? 1 : 0;
    my $file_size       = $rf->{"a"}->size;
    my $file_url        = request()->url_for(
        "backoffice/f_bbdl_download.cgi",
        {
            broker   => $current_broker,
            filename => $rf->{"filename"},
        });

    return {
        file_name       => $rf->{"filename"},
        mdtm            => $bom_mdtm->datetime,
        how_long        => $how_long_ago,
        file_size       => $file_size,
        file_url        => $file_url,
        more_than_a_day => $more_than_a_day,
    };
}

$sftp->disconnect;
