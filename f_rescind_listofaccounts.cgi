#!/usr/bin/perl
package main;

use strict;
use warnings;

use BOM::Platform::Sysinit ();
use f_brokerincludeall;
use BOM::Platform::Transaction;
use BOM::Utility::CurrencyConverter qw(in_USD);
use BOM::Product::Transaction;
use BOM::Platform::Plack qw( PrintContentType );

BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation("RESCIND LIST OF ACCOUNTS");

BOM::Backoffice::Auth0::can_access(['Payments']);
my $clerk = BOM::Backoffice::Auth0::from_cookie()->{nickname};

my $listaccounts = request()->param('listaccounts');
my $message = request()->param('message') || 'Account closed. Please contact customer support for assistance.';
$listaccounts =~ s/ //g;

my $grandtotal = 0;

CLIENT:
foreach my $loginID (split(/,/, $listaccounts)) {

    my $client = eval { BOM::Platform::Client->new({loginid => $loginID}) } || do {
        print "<br/>error: cannot find client '$loginID'";
        next CLIENT;
    };

    my $name  = $client->salutation . ' ' . $client->first_name . ' ' . $client->last_name;
    my $email = $client->email;

    if (not BOM::Platform::Transaction->freeze_client($loginID)) {
        die "Account stuck in previous transaction $loginID";
    }

    my $curr = $client->currency;
    my $b    = $client->default_account->balance;

    if (request()->param('whattodo') eq 'Do it for real !') {

        if (my $sold_bets = BOM::Product::Transaction::sell_expired_contracts({client => $client})) {
            print "<br>[FOR REAL] $loginID ($name $email) Expired bets closed out:";
            print "Account has been credited with <strong>$curr $sold_bets->{total_credited}</strong>";

            if ($sold_bets->{skip_contract} > 0) {
                print "<br>SKIP $loginID $curr as sell $sold_bets->{skip_contract} expired bets failed";
                next CLIENT;
            }
            # recalc balance
            $b = $client->default_account->load->balance;
        }

        if ($b > 0) {
            print "<br>[FOR REAL] $loginID ($name $email) rescinding <b>$curr$b</b>";
            $client->payment_legacy_payment(
                currency     => $curr,
                amount       => -$b,
                remark       => $message,
                payment_type => 'closed_account',
                staff        => $clerk,
            );
        }
    } else {
        print "<br>[Simulate] $loginID ($name $email) <b>$curr$b</b>";
    }
    $grandtotal += in_USD($b, $curr);

    BOM::Platform::Transaction->unfreeze_client($loginID);
}

print "<hr>Grand total recovered (converted to USD): USD $grandtotal<P>";

code_exit_BO();
