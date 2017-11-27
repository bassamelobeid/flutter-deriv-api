#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use JSON::MaybeXS;
use Date::Utility;
use Try::Tiny;
use Data::Dumper;
use HTML::Entities;

use f_brokerincludeall;
use BOM::Platform::Config;
use Client::Account;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();

BOM::Backoffice::Sysinit::init();
PrintContentType();
BrokerPresentation("SHOW CLIENT DESK CASES");

my $loginid;
if (request()->param('loginid_desk')) {
    $loginid = uc(request()->param('loginid_desk'));
}

my $created = 'today';
if (request()->param('created')) {
    $created = lc(request()->param('created'));
}

my $client = Client::Account::get_instance({'loginid' => $loginid});
if (not $client) {
    print "Error : wrong loginID (" . encode_entities($loginid) . ") could not get client instance";
    code_exit_BO();
}

my $curl_url =
      BOM::Platform::Config::third_party->{desk}->{api_uri}
    . "cases/search?q=custom_loginid:$loginid+created:$created -u "
    . BOM::Platform::Config::third_party->{desk}->{username} . ":"
    . BOM::Platform::Config::third_party->{desk}->{password}
    . " -d 'sort_field=created_at&sort_direction=asc' -G -H 'Accept: application/json'";

my $response = `curl $curl_url`;
try {
    $response = JSON::MaybeXS->new->decode(Encode::decode_utf8($response));
    if ($response->{total_entries} > 0 and $response->{_embedded} and $response->{_embedded}->{entries}) {
        print '<table>';
        foreach (sort { Date::Utility->new($a->{created_at})->epoch <=> Date::Utility->new($b->{created_at})->epoch }
            @{$response->{_embedded}->{entries}})
        {
            print '<tr>';
            print '<td>' . encode_entities(Date::Utility->new($_->{created_at})->datetime) . '</td>';
            my $case =
                  '<strong>ID</strong>: '
                . encode_entities($_->{id})
                . ' <strong>description</strong>: '
                . encode_entities($_->{blurb})
                . ' <strong>status</strong>: '
                . encode_entities($_->{status});
            $case .= ' <strong>updated at</strong>: ' . encode_entities(Date::Utility->new($_->{updated_at})->datetime)   if $_->{updated_at};
            $case .= ' <strong>resolved at</strong>: ' . encode_entities(Date::Utility->new($_->{resolved_at})->datetime) if $_->{resolved_at};
            $case .= ' <strong>type</strong>: ' . encode_entities($_->{type})                                             if $_->{type};
            $case .= ' <strong>subject</strong>: ' . encode_entities($_->{subject})                                       if $_->{subject};
            print '<td>' . $case . '</td>';
            print '</tr>';
        }
        print '</table>';
    } else {
        print "No record found";
    }
}
catch {
    print "Desk.com response is " . encode_entities(Dumper($response)) . "</br></br>";
    print "Error is " . encode_entities($_);
};
