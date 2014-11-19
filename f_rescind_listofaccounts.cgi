#!/usr/bin/perl
package main;
use strict 'vars';

use f_brokerincludeall;
use BOM::Platform::Transaction;
use BOM::Utility::CurrencyConverter qw(in_USD);
use BOM::Product::Transaction;
use BOM::Platform::Plack qw( PrintContentType );
system_initialize();

PrintContentType();
BrokerPresentation("RESCIND LIST OF ACCOUNTS");

my $broker = request()->broker->code;
BOM::Platform::Auth0::can_access(['Payments']);

if (BOM::Platform::Runtime->instance->hosts->localhost->canonical_name ne
    BOM::Platform::Runtime->instance->broker_codes->dealing_server_for($broker)->canonical_name)
{
    print "Wrong server for broker code $broker !!";
    code_exit_BO();
}

print "</center></center><font color=white>";

my $listaccounts = request()->param('listaccounts');
my $message = request()->param('message') || 'Account closed. Please contact customer support for assistance.';
$listaccounts =~ s/ //g;

my $grandtotal;

CLIENT:
foreach my $loginID (split(/,/, $listaccounts)) {
    if ($loginID !~ /^$broker\d+$/) { print "ERROR WITH LOGINID $loginID<P>"; next CLIENT; }

    my $client = BOM::Platform::Client::get_instance({'loginid' => $loginID}) || next CLIENT;
    my $name   = $client->salutation . ' ' . $client->first_name . ' ' . $client->last_name;
    my $email  = $client->email;

    if (not BOM::Platform::Transaction->freeze_client($loginID)) {
        die "Account stuck in previous transaction $loginID";
    }

    my $curr        = $client->currency;
    my $bal_account = BOM::Platform::Data::Persistence::DataMapper::Account->new({
            'client_loginid' => $loginID,
            'currency_code'  => $curr,
    });
    my $b = $bal_account->get_balance();

    if (request()->param('whattodo') eq 'Do it for real !') {
        my $sold_bets = BOM::Product::Transaction::sell_expired_contracts({client => $client,});

        if ($sold_bets) {
            print "<br>[FOR REAL] $loginID ($name $email) Expired bets closed out:";
            print "Account has been credited with <strong>$curr $sold_bets->{total_credited}</strong>";

            if ($sold_bets->{skip_contract} > 0) {
                print "<br>SKIP $loginID $curr as sell $sold_bets->{skip_contract} expired bets failed";
                next CURRENCY;
            }
            # recalc balance
            $b = $bal_account->get_balance();
        }

        if ($b > 0) {
            print "<br>[FOR REAL] $loginID ($name $email) rescinding <b>$curr$b</b>";
            ClientDB_Debit({
                    client_loginid => $loginID,
                    currency_code  => $curr,
                    amount         => $b,
                    comment        => $message,
            });
        }
    } else {
        print "<br>[Simulate] $loginID ($name $email) <b>$curr$b</b>";
    }
    $grandtotal += in_USD($b, $curr);

    BOM::Platform::Transaction->unfreeze_client($loginID);
}

print "<hr>Grand total recovered (converted to USD): USD $grandtotal<P>";

code_exit_BO();
