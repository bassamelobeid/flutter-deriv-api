#!/usr/bin/perl
package main;
use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use BOM::Platform::Plack qw/PrintContentType_XSendfile/;
use BOM::Platform::Sysinit ();

use f_brokerincludeall;
BOM::Platform::Sysinit::init();

my $broker = request()->broker->code;
BOM::Backoffice::Auth0::can_access();

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
} elsif ($category eq 'temp') {
    $full_path = BOM::Platform::Runtime->instance->app_config->system->directory->tmp . $path;
} else {
    $full_path = "$dbloc/clientIDscans/$path";
}

local $\ = "";

if (request()->param('deleteit') eq 'yes') {
    PrintContentType();
    BrokerPresentation('DELETE DOCUMENT');
    my $msg;
    if (-s $full_path) {
        my $loginid = request()->param('loginid');
        my $doc_id  = request()->param('doc_id');
        my $client  = BOM::Platform::Client::get_instance({loginid => $loginid});
        if ($client) {
            $client->set_db('write');
            my ($doc) = $client->find_client_authentication_document(query => [id => $doc_id]);    # Rose
            if ($doc) {
                if ($doc->delete) {
                    $msg = "SUCCESS - $path is deleted!";
                    rename $full_path, $full_path.'.'.time.'.deleted' ;
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


if (my ($type) = $path =~ /\.(tif|txt|csv|xls|doc|gif|png|bmp|jpg|jpeg|pdf|zip)$/i) {
    if (-f -r $full_path) {
        PrintContentType_XSendfile($full_path, (lc($type) eq 'pdf' ? 'application/pdf' : 'application/octet-stream'));

        BOM::Platform::Sysinit::code_exit();
    } else {
        PrintContentType();
        print "ERROR: cannot open file ($full_path) $!";
    }
} else {
    print "Content-Type: text/html\n\nUNKNOWN CONTENT TYPE for $path";
}

code_exit_BO();
