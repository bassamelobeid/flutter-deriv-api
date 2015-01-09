#!/usr/bin/perl
package main;
use strict 'vars';

use f_brokerincludeall;
use BOM::Platform::Data::Persistence::DataMapper::Transaction;
use Try::Tiny;
use BOM::Utility::Log4perl qw( get_logger );
use BOM::Platform::Plack qw( PrintContentType_excel );
use BOM::Platform::Sysinit ();
use BOM::Product::ContractFactory qw( produce_contract );

BOM::Platform::Sysinit::init();

local $\ = "\n";

if (request()->param('output') ne 'CSV') {
    die "wrong output type [" . request()->param('output') . "]";
}

PrintContentType_excel(request()->param('action_type') . '_bets_for_' . request()->param('monthonly') . ".csv");

my $broker = request()->broker->code;
BOM::Platform::Auth0::can_access(['Accounts']);

my $action_type = request()->param('action_type');
my $month_only  = BOM::Utility::Date->new('01-' . request()->param('monthonly'))->db_timestamp;

my $txn_mapper = BOM::Platform::Data::Persistence::DataMapper::Transaction->new({
    'broker_code' => $broker,
});

my $bets = $txn_mapper->get_bet_transactions_for_broker({
    'broker_code' => $broker,
    'action_type' => $action_type,
    'month'       => $month_only,
});

print "$action_type transactions\n";
print "transaction time,transaction id, betid, client loginid,residence,quantity,currency code, amount,bet description,is_random";
foreach my $transaction_id (sort { $a cmp $b } keys %{$bets}) {
    my $bet              = $bets->{$transaction_id};
    my $transaction_time = BOM::Utility::Date->new($bet->{'transaction_time'})->datetime_ddmmmyy_hhmmss_TZ;
    my $id               = $bet->{'id'};
    my $bet_id           = $bet->{'bet_id'};
    my $client_loginid   = $bet->{'client_loginid'};
    my $quantity         = $bet->{'quantity'};
    my $currency_code    = $bet->{'currency_code'};
    my $amount           = ($action_type eq 'sell') ? $bet->{'amount'} : -1 * $bet->{'amount'};
    my $residence        = $bet->{residence};

    my ($contract, $is_random);
    my $long_code = '';
    try {
        $contract = produce_contract($bet->{'short_code'}, $currency_code);
        $long_code = $contract->longcode;
        $long_code =~ s/,/ /g;

        $is_random = ($contract->underlying->market->name eq 'random') ? 1 : 0;
    }
    catch {
        get_logger->warn($_);
    };

    print "$transaction_time,$id,$bet_id,$client_loginid,$residence,$quantity,$currency_code,$amount,$long_code,$is_random";
}

print "Number of bets listed above : " . scalar keys %{$bets};

code_exit_BO();

