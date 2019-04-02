#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Guard;
use BOM::Backoffice::Sysinit ();
use f_brokerincludeall;
use BOM::Database::ClientDB;
use ExchangeRates::CurrencyConverter qw(in_usd);
use BOM::Transaction;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("RESCIND LIST OF ACCOUNTS");

my $clerk = BOM::Backoffice::Auth0::get_staffname();

my $listaccounts = request()->param('listaccounts');
my $message = request()->param('message') || 'Account closed.';
$listaccounts =~ s/ //g;

my $grandtotal = 0;

CLIENT:
foreach my $loginID (split(/,/, $listaccounts)) {
    my $encoded_loginID = encode_entities($loginID);
    my $client = eval { BOM::User::Client->new({loginid => $loginID}) } || do {
        print "<br/>error: cannot find client '$encoded_loginID'";
        next CLIENT;
    };

    my $name          = $client->salutation . ' ' . $client->first_name . ' ' . $client->last_name;
    my $email         = $client->email;
    my $encoded_name  = encode_entities($name);
    my $encoded_email = encode_entities($email);

    my $client_db = BOM::Database::ClientDB->new({
        client_loginid => $loginID,
    });

    if (not $client_db->freeze) {
        die "Account stuck in previous transaction $loginID";
    }
    scope_guard {
        $client_db->unfreeze;
    };

    my $curr         = $client->currency;
    my $balance      = $client->default_account->balance;
    my $encoded_curr = encode_entities($curr);

    if (request()->param('whattodo') eq 'Do it for real !') {

        if (my $sold_bets = BOM::Transaction::sell_expired_contracts({client => $client})) {
            print "<br>[FOR REAL] $encoded_loginID ($encoded_name $encoded_email) Expired bets closed out:";
            printf "Account has been credited with <strong>$encoded_curr %s</strong>", encode_entities($sold_bets->{total_credited});

            if ($sold_bets->{skip_contract} > 0) {
                printf "<br>SKIP $encoded_loginID $encoded_curr as sell %s expired bets failed", encode_entities($sold_bets->{skip_contract});
                next CLIENT;
            }
            # recalc balance
            $balance = $client->default_account->balance;
        }

        if ($balance > 0) {
            print "<br>[FOR REAL] $encoded_loginID ($encoded_name $encoded_email) rescinding <b>$encoded_curr$balance</b>";
            $client->payment_legacy_payment(
                currency     => $curr,
                amount       => -$balance,
                remark       => $message,
                payment_type => 'closed_account',
                staff        => $clerk,
            );
        }
    } else {
        print "<br>[Simulate] $encoded_loginID ($encoded_name $encoded_email) <b>$encoded_curr$balance</b>";
    }
    $grandtotal += in_usd($balance, $curr);
}

print "<hr>Grand total recovered (converted to USD): USD $grandtotal<P>";

code_exit_BO();
