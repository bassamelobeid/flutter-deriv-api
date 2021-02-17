#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use CGI;
use HTML::Entities;

use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
use BOM::Config::Runtime;
use BOM::Config;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use Bloomberg::FileDownloader;
use Bloomberg::RequestFiles;
use BOM::Backoffice::QuantsAuditLog;
use BOM::Backoffice::Auth0;
BOM::Backoffice::Sysinit::init();

PrintContentType();

my $cgi       = CGI->new;
my $frequency = $cgi->param('frequency');
my $type      = $cgi->param('type');

BrokerPresentation("BBDL RequestFiles Upload");
Bar("BBDL RequestFiles Upload");

#don't allow from devserver, to avoid uploading wrong files
if (not BOM::Config::on_production()) {
    print "<p class='error'>Sorry, you cannot upload files from a development server. Please use a live server.</p>";
    code_exit_BO();
}

my $bbdl         = Bloomberg::FileDownloader->new();
my $sftp         = $bbdl->login;
my $staff        = BOM::Backoffice::Auth0::get_staffname();
my $request_file = Bloomberg::RequestFiles->new();

my @files;
#regenerate request/cancel files
if ($type eq 'request') {
    $request_file->generate_request_files($frequency);
    my $file_identifier = ($frequency eq 'scheduled') ? 'd' : $frequency eq 'oneshot' ? 'os' : 'ad';
    @files = map { $file_identifier . '_' . $_ } @{$request_file->master_request_files};
} elsif ($type eq 'cancel') {
    $request_file->generate_cancel_files($frequency);
    @files = map { 'c_' . $_ } @{$request_file->master_request_files};
}

my $todo = $type eq 'request' ? 'uploadbbdlmasterrequestfiles' : 'cancelbbdlmasterrequestfiles';
BOM::Backoffice::QuantsAuditLog::log($staff, $todo, 'upload BBDL file');

my $temp_dir = '/tmp';
foreach my $file (@files) {
    my $encoded_file = encode_entities($file);
    if (length($file) >= 25) {
        print "<p class='error'>ERROR: $encoded_file exceeds 25 characters in length</p>";
    } elsif (not -s $temp_dir . '/' . $file) {
        print "<p class='error'>ERROR: $encoded_file does not exist</p>";
    } elsif ($sftp->put($temp_dir . '/' . $file, $file)) {
        print "<p class='success'>UPLOAD $encoded_file SUCCESSFUL</p>";
    } else {
        print "<p class='error'>UPLOAD $encoded_file FAILURE: " . encode_entities($sftp->error) . '</p>';
    }
}

$sftp->disconnect;
