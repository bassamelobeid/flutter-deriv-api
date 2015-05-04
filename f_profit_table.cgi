#!/usr/bin/perl
package main;
use strict 'vars';

use Date::Utility;
use Format::Util::Numbers qw(roundnear);
use BOM::Platform::Client;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Platform::Sysinit ();
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Market::Registry;
use BOM::Platform::CustomClientLimits;
use BOM::View::Controller::Bet;

use Try::Tiny;
use f_brokerincludeall;
BOM::Platform::Sysinit::init();

my $loginID = uc(request()->param('loginID'));

PrintContentType();
BrokerPresentation($loginID . ' Contracts Analysis', '', '');
my $staff = BOM::Platform::Auth0::can_access(['CS']);

if ($loginID !~ /^(\D+)(\d+)$/) {
    print "Error : wrong loginID ($loginID) could not get client instance";
    code_exit_BO();
}

my $client = BOM::Platform::Client::get_instance({'loginid' => $loginID});
if (not $client) {
    print "Error : wrong loginID ($loginID) could not get client instance";
    code_exit_BO();
}

if (request()->param('update_limitlist')) {
    my $limitlist = BOM::Platform::CustomClientLimits->new;
    $limitlist->update({
        loginid       => $loginID,
        market        => request()->param('market'),
        contract_kind => request()->param('contract_kind'),
        payout_limit  => request()->param('payout_limit'),
        comment       => request()->param('limitlist_comment'),
        staff         => BOM::Platform::Auth0::from_cookie()->{nickname},
    });
}

my $startdate = request()->param('startdate');
my $enddate   = request()->param('enddate');

if ($enddate) {
    $enddate = Date::Utility->new($enddate)->plus_time_interval('1d')->date_yyyymmdd;
}

my $db = BOM::Database::ClientDB->new({
        client_loginid => $client->loginid,
    })->db;

Bar($loginID . " - Contracts");
my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new({
    client_loginid => $client->loginid,
    currency_code  => $client->currency,
    db             => $db,
});

my $limits         = BOM::Platform::CustomClientLimits->new->client_limit_list($client->loginid);
my $sold_contracts = $fmb_dm->get_sold({
    after  => $startdate,
    before => $enddate,
    limit  => (request()->param('all') ? 99999 : 50),
});

my $open_contracts = $fmb_dm->get_open_bets_of_account();
foreach my $contract (@{$open_contracts}) {
    $contract->{purchase_date} = Date::Utility->new($contract->{purchase_time});
}

BOM::Platform::Context::template->process(
    'backoffice/account/profit_table.html.tt',
    {
        sold_contracts   => $sold_contracts,
        open_contracts   => $open_contracts,
        limits           => $limits,
        markets          => [BOM::Market::Registry->instance->display_markets],
        email            => $client->email,
        full_name        => $client->full_name,
        loginid          => $client->loginid,
        posted_startdate => $startdate,
        posted_enddate   => $enddate,
        currency         => $client->currency,
        residence        => $client->residence,
        contract_details => \&BOM::View::Controller::Bet::get_info,
    }) || die BOM::Platform::Context::template->error();

code_exit_BO();
