#!/usr/bin/perl
package main;
use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use CGI;
use File::Slurp;

use f_brokerincludeall;
use BOM::Platform::Runtime;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use Bloomberg::FileDownloader;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();

my $cgi       = CGI->new;
my $filename  = $cgi->param('filename');
my $content   = $cgi->param('bbdl_file_content');

Bar("Upload a file to BBDL");

#don't allow from devserver, to avoid uploading wrong files
if (not BOM::Platform::Runtime->instance->app_config->system->on_production) {
    print "<font color=red>Sorry, you cannot upload files from a development server. Please use a live server.</font>";
    code_exit_BO();
}

my $bbdl = Bloomberg::FileDownloader->new();
my $sftp = $bbdl->login;

my $message;
if (length($filename) >= 25) {
    $message = "<font color=red>Error: filename length exceeds 25 characters.</font>";
} else {
    my $temp_dir = '/tmp';
    write_file($temp_dir . '/' . $filename, $content);

    my $replyfile;
    if ($content =~ /REPLYFILENAME=(.+)/m) {
        $replyfile = $1;
        $replyfile = chomp($replyfile);
    }

    $sftp->put($temp_dir . '/' . $filename, $filename);
    if ($sftp->error) {
        $message = "<p>Upload Failed: " . $sftp->error . '</p>';
    } else {
        $message = '<p>Successfully uploaded file[' . $filename . '] to server[' . ']. Your response file is ' . $replyfile . '</p>';
    }

    print $message;
}

$sftp->disconnect;

code_exit_BO();
