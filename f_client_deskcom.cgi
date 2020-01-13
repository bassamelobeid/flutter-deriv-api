#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use Encode;
use JSON::MaybeXS;
use Date::Utility;
use Syntax::Keyword::Try;
use Data::Dumper;
use HTML::Entities;

use f_brokerincludeall;
use BOM::Config;
use BOM::User::Client;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use URI;
use Mojo::UserAgent;

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

my $client = BOM::User::Client::get_instance({
    'loginid'    => $loginid,
    db_operation => 'replica'
});
if (not $client) {
    print "Error : wrong loginID (" . encode_entities($loginid) . ") could not get client instance";
    code_exit_BO();
}

my $ua = Mojo::UserAgent->new;
my $response;

try {
    my $uri = URI->new(BOM::Config::third_party()->{desk}->{api_uri} . 'cases/search');
    $uri->query_param(q              => 'custom_loginid:' . $loginid . ' created:' . $created);
    $uri->query_param(sort_field     => 'created_at');
    $uri->query_param(sort_direction => 'asc');
    $uri->userinfo(BOM::Config::third_party()->{desk}->{username} . ":" . BOM::Config::third_party()->{desk}->{password});
    my $res = $ua->get(
        "$uri",
        => {
            Accept => 'application/json',
        });
    die $res->message if $res->is_error;
    die 'unknown issue with request' unless $res->is_success;
    $response = decode_json_utf8($res->body);

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
    print "Error is " . encode_entities($@);
}
