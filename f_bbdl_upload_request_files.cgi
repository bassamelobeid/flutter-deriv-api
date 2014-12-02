#!/usr/bin/perl
package main;
use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use CGI;

use f_brokerincludeall;
use BOM::Platform::Runtime;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::MarketData::Parser::Bloomberg::FileDownloader;
use BOM::MarketData::Parser::Bloomberg::RequestFiles;

system_initialize();

PrintContentType();

my $cgi               = CGI->new;
my $server_ip         = $cgi->param('server');
my $frequency         = $cgi->param('frequency');
my $volatility_source = $cgi->param('volatility_source');
my $type              = $cgi->param('type');

Bar("BBDL RequestFiles Upload $server_ip");

#don't allow from devserver, to avoid uploading wrong files
if (BOM::Platform::Runtime->instance->app_config->system->on_development) {
    print "<font color=red>Sorry, you cannot upload files from a development server. Please use a live server.</font>";
    code_exit_BO();
}

my $bbdl = BOM::MarketData::Parser::Bloomberg::FileDownloader->new();
$bbdl->ftp_server_ip($server_ip);
my $ftp = $bbdl->login;

my $request_file = BOM::MarketData::Parser::Bloomberg::RequestFiles->new(volatility_source => $volatility_source);

my @files;
#regenerate request/cancel files
if ($type eq 'request') {
    $request_file->generate_request_files($frequency);
    my $file_identifier = ($frequency eq 'daily') ? 'd' : 'os';
    @files = map { $file_identifier . '_' . $_ } @{$request_file->master_request_files};
} elsif ($type eq 'cancel') {
    $request_file->generate_cancel_files($frequency);
    @files = map { 'c_' . $_ } @{$request_file->master_request_files};
}

my $temp_gif_dir = BOM::Platform::Runtime->instance->app_config->system->directory->tmp_gif;
foreach my $file (@files) {
    if (length($file) >= 25) {
        print "<font color=red>ERROR: $file exceeds 25 characters in length</font><br>";
    } elsif (not -s $temp_gif_dir . '/' . $file) {
        print "<font color=red>ERROR: $file does not exist</font><br>";
    } elsif ($ftp->put($temp_gif_dir . '/' . $file, $file)) {
        print "UPLOAD $file SUCCESSFUL<br>";
    } else {
        print "<font color=red>UPLOAD $file FAILURE: " . $ftp->message . '</font><br>';
    }
}

$ftp->quit;
