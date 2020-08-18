#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use HTML::Entities;
use Scalar::Util qw(looks_like_number);
use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Request qw(request);
use BOM::Database::AuthDB;

BOM::Backoffice::Sysinit::init();

PrintContentType();

my $LIMIT  = 100;
my %params = %{request()->params};
my $broker = $params{broker} || request()->broker_code;
BrokerPresentation("EASY SEARCH: $broker");

my $stash = {};

my $tt = BOM::Backoffice::Request::template();

if (my $search = $params{search}) {
    my $clients;
    if (looks_like_number($search)) {
        $clients = BOM::User::Client->get_objects_from_sql(
            broker_code => $broker,
            args        => [$search],
            sql         => qq[select c.* from betonmarkets.client c
                             join transaction.account a
                             on c.loginid = a.client_loginid
                             and not(a.client_loginid like 'VR%')
                             and a.balance >= ?
                             limit $LIMIT ],
        );
    } else {
        my $like = {like => "$search%"};
        $clients = BOM::User::Client->by_args(
            limit       => $LIMIT,
            broker_code => $broker,
            or          => [
                first_name => $like,
                last_name  => $like,
                loginid    => $like,
                email      => $like
            ]);
    }
    my $hits   = @$clients;
    my $caveat = $hits >= $LIMIT ? 'limited to ' : '';
    Bar("Search Results '$search'.. $caveat $hits hits");
    $stash->{clients} = $clients;
    $stash->{search}  = $search;

} elsif (my $loginid = $params{loginid}) {

    my $client = BOM::User::Client->new({
            loginid      => $loginid,
            db_operation => 'replica'
        }) || die "client $loginid not found\n";
    $stash->{client} = $client;

    if (my $binary_user = $client->user) {
        $stash->{binary_user} = $binary_user;
    }

    my $href_args = {loginID => $loginid};
    $stash->{client_href} = request()->url_for("backoffice/f_clientloginid_edit.cgi", $href_args);

    Bar("Client " . $client);
}

$tt->process('backoffice/easy_search.html.tt', $stash)
    || die "Template process failed: " . $tt->error() . "\n";

code_exit_BO();

