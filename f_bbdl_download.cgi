#!/etc/rmg/bin/perl
package main;
use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use CGI;
use File::Copy;
use File::Slurp;
use HTML::Entities;

use f_brokerincludeall;
use BOM::Platform::Runtime;
use BOM::Platform::Config;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use Bloomberg::FileDownloader;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();

my $cgi              = CGI->new;
my $filename         = $cgi->param('filename');
my $encoded_filename = encode_entities($filename);

Bar("Download a file from BBDL");

#don't allow from devserver, to avoid uploading wrong files
if (not BOM::Platform::Config::on_production()) {
    print "<font color=red>Sorry, you cannot upload files from a development server. Please use a live server.</font>";
    code_exit_BO();
}

my $bbdl = Bloomberg::FileDownloader->new();
my $sftp = $bbdl->login;

my $file_stat = $sftp->stat($filename);

my $temp_dir = '/tmp';
my $message;

if ($file_stat) {
    my $mdtm     = $file_stat->mtime;
    my $mod_time = Date::Utility->new($mdtm);
    my $mtime    = $mod_time->datetime . ' = ' . (time - $mod_time->epoch) . 'seconds ago';
    my $size     = $file_stat->size;

    $message .= '<p>File[' . $encoded_filename . '] found with size[' . $size . '] modified[' . $mtime . ']</p>';
}

$sftp->get($filename, "$temp_dir/$filename");
if ($sftp->error) {
    $message .= '<p>DOWNLOAD FAILURE: ' . $sftp->error . '</p>';
} else {
    if ($filename =~ /\.err/) {    # error file
        copy($temp_dir . '/' . $filename, $temp_dir . '/' . $filename . '.txt');
    } else {
        if ($filename =~ /\.gz/) {    # it's gzipped
            print "<p>Sorry, Decrytion Error</p>" and code_exit_BO()
                if (not $bbdl->des_decrypt("$temp_dir/$filename", "$temp_dir/$filename.gz"));
            system("gunzip -c $temp_dir/$filename.gz > $temp_dir/$filename.txt");
        } else {
            $bbdl->des_decrypt("$temp_dir/$filename", "$temp_dir/$filename.txt");
        }
    }

    if (-s $temp_dir . '/' . $filename . '.txt') {
        my @file   = read_file($temp_dir . '/' . $filename . '.txt');
        my $rand   = $$ . $^T;
        my $bo_url = request()->url_for($temp_dir . '/' . $filename . '.txt', {rand => $rand});
        $message .= "<p><a href=$bo_url>$encoded_filename.txt</a> (with " . scalar(@file) . " lines)</p>";
    } else {
        $message .= '<p>Sorry, could not find file[' . $encoded_filename . '] in directory[' . $temp_dir . ']</p>';
    }
}

print $message;

$sftp->disconnect;

code_exit_BO();
