#!/usr/bin/perl
package main;
use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use CGI;
use Carp;

use f_brokerincludeall;

use BOM::Platform::Plack qw( PrintContentType );
use BOM::MarketData::Parser::Bloomberg::FileDownloader;

system_initialize();

PrintContentType();
BrokerPresentation('BBDL LIST DIRECTORY');

my $cgi       = CGI->new;
my $server_ip = $cgi->param('server');
my $broker    = $cgi->param('broker');

my $bbdl = BOM::MarketData::Parser::Bloomberg::FileDownloader->new();
$bbdl->sftp_server_ip($server_ip);
my $ftp = $bbdl->login;

Bar("BBDL Directory Listing $server_ip");

my $ls = $ftp->ls('/') or die "unable to change cwd: " . $ftp->error;

my @request_files  = grep { $_->{'filename'} =~ /\.req$/ } @{$ls};
my @response_files = grep { $_->{'filename'} =~ /\.csv\.enc$/ } @{$ls};

my @request_list  = map { _retrieve_table_data($_) } @request_files;
my @response_list = map { _retrieve_table_data($_) } @response_files;

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

sub _retrieve_table_data {
    my ($rf) = @_;


    my $mdtm            = $rf->{"a"}->mtime;
    my $bom_mdtm        = BOM::Utility::Date->new($mdtm);
    my $how_long_ago    = time - $bom_mdtm->epoch;
    my $more_than_a_day = (time > $mdtm + 86400) ? 1 : 0;
    my $file_size       = $rf->{"a"}->size;
    my $file_url        = request()->url_for(
        "backoffice/f_bbdl_download.cgi",
        {
            broker   => $broker,
            filename => $rf,
            server   => $server_ip
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

$ftp->disconnect;
