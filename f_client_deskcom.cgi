#!/usr/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use JSON;
use Date::Utility;
use Try::Tiny;
use Data::Dumper;

use f_brokerincludeall;
use BOM::Platform::Runtime;
use BOM::Platform::Client;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();

BOM::Platform::Sysinit::init();
PrintContentType();
BrokerPresentation("SHOW CLIENT DESK CASES");

my $loginid;
if (request()->param('loginid_desk')) {
    $loginid = uc(request()->param('loginid_desk'));
}

my $created  = 'today';
if(request()->param('created')) {
    $created = lc(request()->param('created'));
}

my $client = BOM::Platform::Client::get_instance({'loginid' => $loginid});
if (not $client) {
    print "Error : wrong loginID ($loginid) could not get client instance";
    code_exit_BO();
}

my $curl_url = BOM::Platform::Runtime->instance->app_config->system->desk_com->desk_url . "cases/search?q=custom_loginid:$loginid+created:$created -u " . BOM::Platform::Runtime->instance->app_config->system->desk_com->account_username . ":" . BOM::Platform::Runtime->instance->app_config->system->desk_com->account_password . " -d 'sort_field=created_at&sort_direction=asc' -G -H 'Accept: application/json'";

my $response = `curl $curl_url`;
try {
    $response = decode_json $response;
    if ($response->{total_entries} > 0 and $response->{_embedded} and $response->{_embedded}->{entries}) {
        print '<table>';
        foreach (sort { Date::Utility->new($a->{created_at})->epoch <=> Date::Utility->new($b->{created_at})->epoch } @{$response->{_embedded}->{entries}} ) {
            print '<tr>';
            print '<td>' . Date::Utility->new($_->{created_at})->datetime . '</td>';
            my $case = '<strong>ID</strong>: ' . $_->{id} . ' <strong>description</strong>: ' . $_->{blurb} .  ' <strong>status</strong>: ' . $_->{status};
            $case .= ' <strong>updated at</strong>: ' . Date::Utility->new($_->{updated_at})->datetime if $_->{updated_at};
            $case .= ' <strong>resolved at</strong>: ' . Date::Utility->new($_->{resolved_at})->datetime if $_->{resolved_at};
            $case .= ' <strong>type</strong>: ' . $_->{type} if $_->{type};
            $case .= ' <strong>subject</strong>: ' . $_->{subject} if $_->{subject};
            print '<td>' . $case . '</td>';
            print '</tr>';
        }
        print '</table>';
    } else {
        print "No record found";
    }
} catch {
    print "Desk.com response is " . Dumper($response) . "</br></br>";
    print "Error is " . $_;
}
