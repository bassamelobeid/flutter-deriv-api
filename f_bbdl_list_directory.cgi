#!/usr/bin/perl
package main;
use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use CGI;
use Carp qw( croak );

use f_brokerincludeall;

use BOM::Platform::Plack qw( PrintContentType );
use Bloomberg::FileDownloader;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('BBDL LIST DIRECTORY');

my $cgi       = CGI->new;
my $server_ip = $cgi->param('server');
my $broker    = $cgi->param('broker');

my $bbdl = Bloomberg::FileDownloader->new();
$bbdl->sftp_server_ip($server_ip);
my $sftp = $bbdl->login;

Bar("BBDL Directory Listing $server_ip");

my $ls = $sftp->ls('/') or die "unable to change cwd: " . $sftp->error;

my @request_files  = grep { $_->{'filename'} =~ /\.req$/ } @{$ls};
my @response_files = grep { $_->{'filename'} =~ /\.csv\.enc$/ } @{$ls};

my @request_list  = map { _retrieve_table_data($_, $broker, $server_ip) } @request_files;
my @response_list = map { _retrieve_table_data($_, $broker, $server_ip) } @response_files;

if (@request_list) {
    my $request_f;
    BOM::Platform::Context::template->process(
        'backoffice/bbdl/list_directory.html.tt',
        {
            file_type => 'REQUEST FILES',
            args      => \@request_list
        },
        \$request_f
    ) || croak BOM::Platform::Context::template->error();

    print $request_f;
    print "</br></br>";
}

if (@response_list) {
    my $response_f;

    BOM::Platform::Context::template->process(
        'backoffice/bbdl/list_directory.html.tt',
        {
            file_type => 'RESPONSE FILES',
            args      => \@response_list
        },
        $response_f
    ) || croak BOM::Platform::Context::template->error();

    print $response_f;
}

sub _retrieve_table_data {
    my ($rf, $current_broker, $server_ip_addr) = @_;

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
            server   => $server_ip_addr
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
