#!/usr/bin/perl
package main;
use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use Symbol qw( gensym );
use BOM::Platform::Plack qw/PrintContentType_XSendfile/;

use f_brokerincludeall;
system_initialize();

my $broker = request()->broker->code;
BOM::Platform::Auth0::can_access();

# category: id_scan (Default), 192_result
my $category = request()->param('category');
# Path can be directory or file path
my $path = request()->param('path');

# hacker checks
if ($path =~ /\?|,|;|:|\~|\%2F|\^/i)   { PrintContentType(); print "Wrong input $path";     code_exit_BO(); }
if ($path =~ /\.\./)                   { PrintContentType(); print "Wrong input (2) $path"; code_exit_BO(); }
if ($path =~ /\>/)                     { PrintContentType(); print "Wrong input (3) $path"; code_exit_BO(); }
if ($path =~ /\</)                     { PrintContentType(); print "Wrong input (4) $path"; code_exit_BO(); }
if ($path =~ /[\<\>\?\,\[\]\{\}\*\`]/) { PrintContentType(); print "Wrong input (5) $path"; code_exit_BO(); }

my $dbloc = BOM::Platform::Runtime->instance->app_config->system->directory->db;

my $full_path;
if ($category eq '192_result') {
    $full_path = "$dbloc/f_accounts/$broker/192com_authentication/$path";
} elsif ($category eq 'attorney_granters') {
    $full_path = "$dbloc/attorney_granters/$broker/$path";
} elsif ($category eq 'temp') {
    $full_path = BOM::Platform::Runtime->instance->app_config->system->directory->tmp . $path;
} else {
    $full_path = "$dbloc/clientIDscans/$path";
}

# List a directory
if (-d $full_path) {
    PrintContentType();
    $\ = "\n";

    my @directorycontents;

    local *DIREC;
    if (not opendir(DIREC, $full_path)) {
        print "Can not read directory $!";
        code_exit_BO();
    }

    @directorycontents = ();
    while (my $l = readdir(DIREC)) {
        if (($l !~ /^\./) and ($l !~ /WS_FTP\.LOG/i)) {
            my $createtime = (-M "$full_path/$l");
            my $encodedl   = "$path/$l";
            $encodedl =~ s/\s/+/g;
            $encodedl =~ s/\&/%26/g;
            if (-d "$full_path/$l") {
                push @directorycontents,
                      "<!-- $createtime -->"
                    . "<li><strong><font size=\"4\">$path/<a href='"
                    . request()->url_for(
                    'backoffice/download_document.cgi',
                    {
                        category => $category,
                        path     => $encodedl,
                        broker   => $broker
                    }) . "'>$l</a></font></strong></li>";
            } else {
                #use normal cgi on this one because of content-type
                push @directorycontents,
                      "<!-- $createtime -->" . "<li>"
                    . "<font size=\"4\">$path/<a target='$createtime' href='"
                    . request()->url_for(
                    'backoffice/download_document.cgi',
                    {
                        category => $category,
                        path     => $encodedl,
                        broker   => $broker
                    })
                    . "'>$l</a></font>&nbsp;"
                    . '<font size="1">(Last modified '
                    . (int($createtime * 10) / 10)
                    . ' days ago.  File size : '
                    . (-s "$full_path/$l")
                    . ')</font>' . '</li>';
            }
        }
    }

    closedir DIREC;

    my $a1;
    my $b1;

    @directorycontents = sort {
        $a =~ /--\s(\d*\.?\d*)\s--/;
        $a1 = $1;
        $b =~ /--\s(\d*\.?\d*)\s--/;
        $b1 = $1;
        $b1 <=> $a1;
    } @directorycontents;

    print "$path<ul>";
    print @directorycontents;
    print "</ul>";
}
# Output a file
else {
    if (request()->param('deleteit') eq 'yes') {
        PrintContentType();
        BrokerPresentation('DELETE DOCUMENT');
        my $msg;
        if (-s $full_path) {
            # remove client authentication document record from client db
            my $loginid = request()->param('loginid');
            my $doc_id  = request()->param('doc_id');
            my $client  = BOM::Platform::Client::get_instance({loginid => $loginid});
            if ($client) {
                $client->set_db('write');
                my ($doc) = $client->find_client_authentication_document(query => [id => $doc_id]);    # Rose
                if ($doc) {
                    if ($doc->delete) {
                        $msg = "SUCCESS - $path is deleted!";
                        unlink $full_path;
                    } else {
                        $msg = "ERROR: did not remove $path record from db";
                    }
                } else {
                    $msg = "ERROR: could not find $path record in db";
                }
            } else {
                $msg = "ERROR: with client login $loginid";
            }
        } else {
            $msg = "ERROR: $full_path does not exist or is empty!";
        }
        print "<p>$msg</p>";
        code_exit_BO();
    }

    local $\ = "";

    if (my ($type) = $path =~ /\.(tif|txt|csv|xls|doc|gif|png|bmp|jpg|jpeg|pdf|zip)$/i) {
        if (-f -r $full_path) {
            PrintContentType_XSendfile($full_path, (lc($type) eq 'pdf' ? 'application/pdf' : 'application/octet-stream'));

            code_exit();
        } else {
            PrintContentType();
            print "ERROR: cannot open file ($full_path) $!";
        }
    } else {
        print "Content-Type: text/html\n\nUNKNOWN CONTENT TYPE for $path";
    }
}

code_exit_BO();
