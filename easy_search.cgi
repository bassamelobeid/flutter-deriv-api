#!/usr/bin/perl
package main;

use strict;
use warnings;
use Scalar::Util qw(looks_like_number);
use f_brokerincludeall;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();

my $LIMIT  = 100;
my %params = %{request()->params};
my $broker = $params{broker} || request()->broker->code;
BrokerPresentation("EASY SEARCH: $broker");

my $staff = BOM::Platform::Auth0::can_access(['CS']);

my $stash = {broker => $broker};

my $tt = BOM::Platform::Context::template();

if (my $search = $params{search}) {
    my $clients;
    if (looks_like_number($search)) {
        $clients = BOM::Platform::Client->get_objects_from_sql(
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
        $clients = BOM::Platform::Client->by_args(
            limit       => $LIMIT,
            broker_code => $broker,
            or          => [
                first_name => $like,
                last_name  => $like,
                loginid    => $like,
                email      => $like
            ]);
    }
    my $hits = @$clients;
    my $caveat = $hits >= $LIMIT ? 'limited to ' : '';
    Bar("Search Results '$search'.. $caveat $hits hits");
    $stash->{clients} = $clients;
    $stash->{search}  = $search;

} elsif (my $loginid = $params{loginid}) {
    my $client = BOM::Platform::Client->new({loginid => $loginid}) || die "client $loginid not found\n";
    my $href_args = {
        loginID => $loginid,
        broker  => $broker
    };
    $stash->{client_href} = request()->url_for("backoffice/f_clientloginid_edit.cgi", $href_args);
    $stash->{client} = $client;
    Bar("Client $client");
}

$tt->process('backoffice/easy_search.html.tt', $stash)
    || die "Template process failed: " . $tt->error() . "\n";

code_exit_BO();

