#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Date::Utility;
use Format::Util::Numbers qw(roundcommon);
use Machine::Epsilon;
use HTML::Entities;

use Brands;
use BOM::User::Client;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use Finance::Asset::Market::Registry;
use BOM::ContractInfo;

use Performance::Probability qw(get_performance_probability);

use f_brokerincludeall;
BOM::Backoffice::Sysinit::init();

my $loginID = uc(request()->param('loginID') // '');
my $encoded_loginID = encode_entities($loginID);

PrintContentType();
BrokerPresentation($encoded_loginID . ' Contracts Analysis', '', '');

if ($loginID !~ /^(\D+)(\d+)$/) {
    print "Error : wrong loginID ($encoded_loginID) could not get client instance";
    code_exit_BO();
}

my $client = BOM::User::Client::get_instance({
    'loginid'    => $loginID,
    db_operation => 'replica'
});
if (not $client) {
    print "Error : wrong loginID ($encoded_loginID) could not get client instance";
    code_exit_BO();
}

my $from_date = request()->param('startdate');
my $to_date   = request()->param('enddate');

if ($from_date && $to_date && $from_date =~ m/^\d{4}-\d{2}-\d{2}$/ && $to_date =~ m/^\d{4}-\d{2}-\d{2}$/) {
    $from_date .= ' 00:00:00';
    $to_date   .= ' 23:59:59';
}

my $clientdb = BOM::Database::ClientDB->new({
    client_loginid => $client->loginid,
});

Bar($loginID . " - Contracts");
my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new({
    client_loginid => $client->loginid,
    currency_code  => $client->currency,
    db             => $clientdb->db,
});

# since get_sold uses after (> sign) and before (< sign)
# we want the time to be inclusive of from_date (>= sign) and to_date (<= sign)
# so we add and minus 1 second to make it same as >= or <=
# underlying of client_statement_for_backoffice uses get_transactions and get_payments
# which handles undef accordingly.
my $sold_contracts = $fmb_dm->get_sold({
    after  => $from_date ? Date::Utility->new($from_date)->minus_time_interval('1s')->datetime_yyyymmdd_hhmmss() : undef,
    before => $to_date   ? Date::Utility->new($to_date)->plus_time_interval('1s')->datetime_yyyymmdd_hhmmss()    : undef,
    limit  => 50
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

my $performance_probability;
my $inv_performance_probability;

if (defined $do_calculation) {

    foreach my $contract (@{$sold_contracts}) {
        my $start_epoch = Date::Utility->new($contract->{start_time})->epoch;
        my $sell_epoch  = Date::Utility->new($contract->{sell_time})->epoch;

        if ($contract->{bet_type} =~ /^CALL/ or $contract->{bet_type} =~ /^PUT/) {
            push @start_time,        $start_epoch;
            push @sell_time,         $sell_epoch;
            push @buy_price,         $contract->{buy_price};
            push @payout_price,      $contract->{payout_price};
            push @bet_type,          $contract->{bet_type};
            push @underlying_symbol, $contract->{underlying_symbol};

            $cumulative_pnl = $cumulative_pnl + ($contract->{sell_price} - $contract->{buy_price});
        }
    }

    if (scalar(@start_time) > 0) {
        $performance_probability = Performance::Probability::get_performance_probability({
            payout       => \@payout_price,
            bought_price => \@buy_price,
            pnl          => $cumulative_pnl,
            types        => \@bet_type,
            underlying   => \@underlying_symbol,
            start_time   => \@start_time,
            sell_time    => \@sell_time,
        });

        $inv_performance_probability = roundcommon(0.01, 1 / ($performance_probability + machine_epsilon()));
        $performance_probability     = (1 - $performance_probability) * 100;
        $performance_probability     = roundcommon(0.001, $performance_probability);
    }
}

my $open_contracts = get_open_contracts($client);
foreach my $contract (@$open_contracts) {
    $contract->{purchase_date} = Date::Utility->new($contract->{purchase_time});
}

BOM::Backoffice::Request::template()->process(
    'backoffice/account/profit_table.html.tt',
    {
        sold_contracts   => $sold_contracts,
        open_contracts   => $open_contracts,
        markets          => [Finance::Asset::Market::Registry->instance->display_markets],
        email            => $client->email,
        full_name        => $client->full_name,
        loginid          => $client->loginid,
        posted_startdate => $from_date ? Date::Utility->new($from_date)->datetime_yyyymmdd_hhmmss() : undef,
        posted_enddate   => $to_date ? Date::Utility->new($to_date)->datetime_yyyymmdd_hhmmss() : undef,
        currency         => $client->currency,
        residence        => Brands->new(name => request()->brand)->countries_instance->countries->country_from_code($client->residence),
        contract_details => \&BOM::ContractInfo::get_info,
        performance_probability     => $performance_probability,
        inv_performance_probability => $inv_performance_probability,
    }) || die BOM::Backoffice::Request::template()->error();

code_exit_BO();
