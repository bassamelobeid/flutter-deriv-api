#!/usr/bin/perl
package main;
use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use CGI;

use f_brokerincludeall;
use BOM::Platform::Sysinit ();
use BOM::Platform::Runtime;
use BOM::Platform::Plack qw( PrintContentType );
use Bloomberg::FileDownloader;
use Bloomberg::RequestFiles;

BOM::Platform::Sysinit::init();

PrintContentType();

my $cgi       = CGI->new;
my $frequency = $cgi->param('frequency');
my $type      = $cgi->param('type');

Bar("BBDL RequestFiles Upload");

#don't allow from devserver, to avoid uploading wrong files
if (not BOM::Platform::Runtime->instance->app_config->system->on_production) {
    print "<font color=red>Sorry, you cannot upload files from a development server. Please use a live server.</font>";
    code_exit_BO();
}

my $bbdl = Bloomberg::FileDownloader->new();
my $sftp = $bbdl->login;

my $request_file = Bloomberg::RequestFiles->new();

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

my $temp_dir = '/tmp';
foreach my $file (@files) {
    if (length($file) >= 25) {
        print "<font color=red>ERROR: $file exceeds 25 characters in length</font><br>";
    } elsif (not -s $temp_dir . '/' . $file) {
        print "<font color=red>ERROR: $file does not exist</font><br>";
    } elsif ($sftp->put($temp_dir . '/' . $file, $file)) {
        print "UPLOAD $file SUCCESSFUL<br>";
    } else {
        print "<font color=red>UPLOAD $file FAILURE: " . $sftp->error . '</font><br>';
    }
}

$sftp->disconnect;
