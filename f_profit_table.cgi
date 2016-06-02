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
use BOM::Product::CustomClientLimits;
use BOM::ContractInfo;

use Performance::Probability qw(get_performance_probability);

use f_brokerincludeall;
BOM::Platform::Sysinit::init();

my $loginID = uc(request()->param('loginID'));

PrintContentType();
BrokerPresentation($loginID . ' Contracts Analysis', '', '');
my $staff = BOM::Backoffice::Auth0::can_access(['CS']);

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
    my $limitlist = BOM::Product::CustomClientLimits->new;
    $limitlist->update({
        loginid       => $loginID,
        market        => request()->param('market'),
        contract_kind => request()->param('contract_kind'),
        payout_limit  => request()->param('payout_limit'),
        comment       => request()->param('limitlist_comment'),
        staff         => BOM::Backoffice::Auth0::from_cookie()->{nickname},
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

my $limits         = BOM::Product::CustomClientLimits->new->client_limit_list($client->loginid);
my $sold_contracts = $fmb_dm->get_sold({
    after  => $startdate,
    before => $enddate,
    limit  => (request()->param('all') ? 99999 : 50),
});

#Performance probability
my $do_calculation = request()->param('calc_performance_probability');

my @buy_price;
my @payout_price;
my @start_time;
my @sell_time;
my @underlying_symbol;
my @bet_type;

my $cumulative_pnl = 0;

my $performance_probability = undef;

print "$do_calculation";

if (defined $do_calculation) {

    foreach my $contract (@{$sold_contracts}) {
        my $start_epoch = Date::Utility->new($contract->{start_time})->epoch;
        my $sell_epoch  = Date::Utility->new($contract->{sell_time})->epoch;

        push @start_time,        $start_epoch;
        push @sell_time,         $sell_epoch;
        push @buy_price,         $contract->{buy_price};
        push @payout_price,      $contract->{payout_price};
        push @bet_type,          $contract->{bet_type};
        push @underlying_symbol, $contract->{underlying_symbol};

        $cumulative_pnl = $cumulative_pnl + ($contract->{sell_price} - $contract->{buy-price});
    }

    $performance_probability = Performance::Probability::get_performance_probability({
        payout       => \@payout_price,
        bought_price => \@buy_price,
        pnl          => $cumulative_pnl,
        types        => \@bet_type,
        underlying   => \@underlying_symbol,
        start_time   => \@start_time,
        sell_time    => \@sell_time,
    });


    print $performance_probability;
}

my $open_contracts = $fmb_dm->get_open_bets_of_account();
foreach my $contract (@{$open_contracts}) {
    $contract->{purchase_date} = Date::Utility->new($contract->{purchase_time});
}

BOM::Platform::Context::template->process(
    'backoffice/account/profit_table.html.tt',
    {
        sold_contracts          => $sold_contracts,
        open_contracts          => $open_contracts,
        limits                  => $limits,
        markets                 => [BOM::Market::Registry->instance->display_markets],
        email                   => $client->email,
        full_name               => $client->full_name,
        loginid                 => $client->loginid,
        posted_startdate        => $startdate,
        posted_enddate          => $enddate,
        currency                => $client->currency,
        residence               => $client->residence,
        contract_details        => \&BOM::ContractInfo::get_info,
        performance_probability => $performance_probability,
    }) || die BOM::Platform::Context::template->error();

code_exit_BO();
