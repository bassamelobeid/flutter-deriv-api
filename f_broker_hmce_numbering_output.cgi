#!/usr/bin/perl
package main;
use strict 'vars';

use f_brokerincludeall;
use BOM::Database::DataMapper::Transaction;
use Try::Tiny;
use BOM::Platform::Plack qw( PrintContentType_excel );
use BOM::Platform::Sysinit ();
use BOM::Product::ContractFactory qw( simple_contract_info );

BOM::Platform::Sysinit::init();

local $\ = "\n";

if (request()->param('output') ne 'CSV') {
    die "wrong output type [" . request()->param('output') . "]";
}

PrintContentType_excel(request()->param('action_type') . '_bets_for_' . request()->param('start') . ".csv");

my $broker = request()->broker->code;
BOM::Backoffice::Auth0::can_access(['Accounts']);

my $action_type = request()->param('action_type');
my $start       = Date::Utility->new(request()->param('start'))->db_timestamp;
my $end         = Date::Utility->new(request()->param('end'))->db_timestamp;

my $txn_mapper = BOM::Database::DataMapper::Transaction->new({
    broker_code => $broker,
    operation   => 'backoffice_replica',
});

my $bets = $txn_mapper->get_bet_transactions_for_broker({
    broker_code => $broker,
    action_type => $action_type,
    start       => $start,
    end         => $end
});

print "$action_type transactions\n";
print "transaction time,transaction id, betid, client loginid,residence,quantity,currency code, amount,bet description,is_random";
foreach my $transaction_id (sort { $a cmp $b } keys %{$bets}) {
    my $bet              = $bets->{$transaction_id};
    my $transaction_time = Date::Utility->new($bet->{'transaction_time'})->datetime_ddmmmyy_hhmmss_TZ;
    my $id               = $bet->{'id'};
    my $bet_id           = $bet->{'bet_id'};
    my $client_loginid   = $bet->{'client_loginid'};
    my $quantity         = $bet->{'quantity'};
    my $currency_code    = $bet->{'currency_code'};
    my $amount           = ($action_type eq 'sell') ? $bet->{'amount'} : -1 * $bet->{'amount'};
    my $residence        = $bet->{residence};
    my $symbol           = $bet->{underlying_symbol};
    my $short_code       = $bet->{short_code};

    my $is_random = ($symbol =~ /^RD/ or $symbol =~ /^R_/) ? 1 : 0;
    my $long_code = '';
    try {
        ($long_code) = simple_contract_info($short_code, $currency_code);
        $long_code =~ s/,/ /g;
    }
    catch {
        warn("shortcode[$short_code]. curr[$currency_code], $_");
    };

    print "$transaction_time,$id,$bet_id,$client_loginid,$residence,$quantity,$currency_code,$amount,$long_code,$is_random";
}

print "Number of bets listed above : " . scalar keys %{$bets};

code_exit_BO();

