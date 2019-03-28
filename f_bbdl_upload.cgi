#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use CGI;
use Path::Tiny;
use HTML::Entities;

use f_brokerincludeall;
use BOM::Config::Runtime;
use BOM::Config;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use Bloomberg::FileDownloader;
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::QuantsAuditLog;
use BOM::Backoffice::Auth0;
BOM::Backoffice::Sysinit::init();

PrintContentType();

my $cgi      = CGI->new;
my $filename = $cgi->param('filename');
my $content  = $cgi->param('bbdl_file_content');
my $staff    = BOM::Backoffice::Auth0::from_cookie()->{nickname};
Bar("Upload a file to BBDL");

#don't allow from devserver, to avoid uploading wrong files
if (not BOM::Config::on_production()) {
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
    path($temp_dir . '/' . $filename)->spew_utf8($content);

    my $replyfile;
    if ($content =~ /REPLYFILENAME=(.+)/m) {
        $replyfile = $1;
        $replyfile = chomp($replyfile);
    }

    $sftp->put($temp_dir . '/' . $filename, $filename);
    if ($sftp->error) {
        $message = "<p>Upload Failed: " . $sftp->error . '</p>';
    } else {
        $message =
              '<p>Successfully uploaded file['
            . encode_entities($filename)
            . '] to server['
            . ']. Your response file is '
            . encode_entities($replyfile) . '</p>';
        BOM::Backoffice::QuantsAuditLog::log($staff, 'manuallyuploadbbdlrequest', $content);

    }

    print $message;
}

$sftp->disconnect;

code_exit_BO();
