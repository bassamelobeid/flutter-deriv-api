#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings

use open qw[ :encoding(UTF-8) ];

use HTML::Entities;
use BOM::Backoffice::PlackHelpers qw/PrintContentType_XSendfile/;
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Config qw/get_tmp_path_or_die/;

use Client::Account;

use f_brokerincludeall;
BOM::Backoffice::Sysinit::init();

my $broker = request()->broker_code;

# category: id_scan (Default), 192_result
my $category = request()->param('category');
# Path can be directory or file path
my $path         = request()->param('path');
my $encoded_path = encode_entities($path);

# hacker checks
if ($path =~ /\?|,|;|:|\~|\%2F|\^/i)   { PrintContentType(); print "Wrong input $encoded_path";     code_exit_BO(); }
if ($path =~ /\.\./)                   { PrintContentType(); print "Wrong input (2) $encoded_path"; code_exit_BO(); }
if ($path =~ /\>/)                     { PrintContentType(); print "Wrong input (3) $encoded_path"; code_exit_BO(); }
if ($path =~ /\</)                     { PrintContentType(); print "Wrong input (4) $encoded_path"; code_exit_BO(); }
if ($path =~ /[\<\>\?\,\[\]\{\}\*\`]/) { PrintContentType(); print "Wrong input (5) $encoded_path"; code_exit_BO(); }

my $dbloc = BOM::Platform::Runtime->instance->app_config->system->directory->db;

my $full_path;
if ($category eq '192_result') {
    $full_path = "$dbloc/f_accounts/$broker/192com_authentication/$path";
} elsif ($category eq 'temp') {
    $full_path = get_tmp_path_or_die() . $path;
} else {
    $full_path = $path;
}

local $\ = "";

if (request()->param('deleteit') eq 'yes') {
    PrintContentType();
    BrokerPresentation('DELETE DOCUMENT');
    my $msg;
    my $loginid = encode_entities(request()->param('loginid'));
    my $doc_id  = request()->param('doc_id');
    my $client  = Client::Account::get_instance({loginid => $loginid});
    if ($client) {
        $client->set_db('write');
        my ($doc) = $client->find_client_authentication_document(query => [id => $doc_id]);    # Rose
        if ($doc) {
            if ($doc->delete) {
                $msg = "SUCCESS - $encoded_path is deleted!";
            } else {
                $msg = "ERROR: did not remove $encoded_path record from db";
            }
        } else {
            $msg = "ERROR: could not find $encoded_path record in db";
        }
        $msg .=
              '<p>Go back to client details <a href="'
            . request()->url_for("backoffice/f_clientloginid_edit.cgi", {loginID => $loginid}) . '">'
            . $loginid . '</p>';

    } else {
        $msg = "ERROR: with client login " . $loginid;
    }
    print "<p>$msg</p>";
    code_exit_BO();
}

if (my ($type) = $path =~ /\.(tif|txt|csv|xls|doc|gif|png|bmp|jpg|jpeg|pdf|zip|mp4)$/i) {
    if (-f -r $full_path) {
        PrintContentType_XSendfile($full_path, (lc($type) eq 'pdf' ? 'application/pdf' : 'application/octet-stream'));

        code_exit_BO();
    } else {
        PrintContentType();
        print "ERROR: cannot open file (" . encode_entities($full_path) . ") $!";
    }
} else {
    print "Content-Type: text/html\n\nUNKNOWN CONTENT TYPE for $encoded_path";
}

code_exit_BO();
