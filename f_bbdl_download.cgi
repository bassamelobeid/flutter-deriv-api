#!/usr/bin/perl
package main;
use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use CGI;
use File::Copy;
use File::Slurp;

use f_brokerincludeall;
use BOM::Platform::Runtime;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::MarketData::Parser::Bloomberg::FileDownloader;

system_initialize();

PrintContentType();

my $cgi       = CGI->new;
my $server_ip = $cgi->param('server');
my $filename  = $cgi->param('filename');

Bar("Download a file from BBDL $server_ip");

#don't allow from devserver, to avoid uploading wrong files
if (BOM::Platform::Runtime->instance->app_config->system->on_development) {
    print "<font color=red>Sorry, you cannot upload files from a development server. Please use a live server.</font>";
    code_exit_BO();
}

my $bbdl = BOM::MarketData::Parser::Bloomberg::FileDownloader->new();
$bbdl->sftp_server_ip($server_ip);
my $sftp = $bbdl->login;

my $file_stat = $sftp->stat($filename);

my $gif_temp_dir = BOM::Platform::Runtime->instance->app_config->system->directory->tmp_gif;
my $message;

if ($file_stat) {
    my $mdtm         = $file_stat->mtime;
    my $mod_time     = BOM::Utility::Date->new($mdtm);
    my $mtime        = $mod_time->datetime . ' = ' . (time - $mod_time->epoch) . 'seconds ago';
    my $size         = $file_stat->size;

    $message .= '<p>File[' . $filename . '] found with size[' . $size . '] modified[' . $mtime . ']</p>';
}

$sftp->get($filename, "$gif_temp_dir/$filename");
if ($sftp->error) {
    $message .= '<p>DOWNLOAD FAILURE: ' . $sftp->error . '</p>';
} else {
    if ($filename =~ /\.err/) {    # error file
        copy($gif_temp_dir . '/' . $filename, $gif_temp_dir . '/' . $filename . '.txt');
    } else {
        if ($filename =~ /\.gz/) {    # it's gzipped
            print "<p>Sorry, Decrytion Error</p>" and code_exit_BO()
              if (not $bbdl->des_decrypt("$gif_temp_dir/$filename", "$gif_temp_dir/$filename.gz"));
            system("gunzip -c $gif_temp_dir/$filename.gz > $gif_temp_dir/$filename.txt");
        } else {
            $bbdl->des_decrypt("$gif_temp_dir/$filename", "$gif_temp_dir/$filename.txt");
        }
    }

    if (-s $gif_temp_dir . '/' . $filename . '.txt') {
        my @file   = read_file($gif_temp_dir . '/' . $filename . '.txt');
        my $rand   = $$ . $^T;
        my $bo_url = request()->url_for('temp/' . $filename . '.txt', {rand => $rand});
        $message .= "<p><a href=$bo_url>$filename.txt</a> (with " . scalar(@file) . " lines)</p>";
    } else {
        $message .= '<p>Sorry, could not find file[' . $filename . '] in directory[' . $gif_temp_dir . ']</p>';
    }
}

print $message;

$sftp->disconnect;

code_exit_BO();
