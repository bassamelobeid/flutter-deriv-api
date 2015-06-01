#!/usr/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use JSON;
use WWW::Desk;
use WWW::Desk::Auth::HTTP;
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

my $loginid  = uc(request()->param('loginid_desk'));
my $created  = request()->param('created');

my $client = BOM::Platform::Client::get_instance({'loginid' => $loginid});
if (not $client) {
    print "Error : wrong loginID ($loginid) could not get client instance";
    code_exit_BO();
}

my $auth = WWW::Desk::Auth::HTTP->new(
    'username' => BOM::Platform::Runtime->instance->app_config->system->desk_com->account_username,
    'password' => BOM::Platform::Runtime->instance->app_config->system->desk_com->account_password
);

my $desk = WWW::Desk->new(
    'desk_url'       => BOM::Platform::Runtime->instance->app_config->system->desk_com->desk_url,
    'authentication' => $auth,
);

my $query_string = "?q=custom_loginid:$loginid";
$query_string .= "+created:" . lc($created) if $created;

my $response = $desk->call('/cases/search' . $query_string, 'GET', {'locale' => 'en_US'});
try {
    $response = decode_json $response;
    if ($response->{_embedded} and $response->{_embedded}->{entries}) {
        print '<table>';
        foreach (sort { Date::Utility->new($a->{created_at})->epoch <=> Date::Utility->new($b->{created_at})->epoch } @{$response->{_embedded}->{entries}} ) {
            print '<tr>';
            print '<td>' . Date::Utility->new($_->{created_at})->datetime . '</td>';
            my $case = 'ID: ' . $_->{id} . ' description: ' . $_->{blurb} .  ' status: ' . $_->{status};
            $case .= ' updated at: ' . Date::Utility->new($_->{updated_at})->datetime if $_->{updated_at};
            $case .= ' resolved at: ' . Date::Utility->new($_->{resolved_at})->datetime if $_->{resolved_at};
            $case .= ' type: ' . $_->{type} if $_->{type};
            $case .= ' subject ' . $_->{subject} if $_->{subject};
            print '<td>' . $case . '</td>';
            print '</tr>';
        }
        print '</table>';
    }
} catch {
    print "Desk.com response is " . Dumper($response) . "</br></br>";
    print "Error is " . $_;
}
