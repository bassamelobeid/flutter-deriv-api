#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;

use BOM::User::Client;
use HTML::Entities;
use BOM::Database::DataMapper::Account;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();

my $login         = request()->param('login');
my $encoded_login = encode_entities($login);

BrokerPresentation('CLIENT LIMITS FOR ' . $encoded_login);

# Withdrawal limits
my $client = eval { BOM::User::Client::get_instance({'loginid' => $login, db_operation => 'replica'}) };

if (!$client) {
    code_exit_BO("ERROR: Wrong loginID $encoded_login");
}

my $curr = $client->currency;

my $account_mapper = BOM::Database::DataMapper::Account->new({
    client_loginid => $login,
    currency_code  => $curr,
});
my $bal = $account_mapper->get_balance();

Bar($login . ' withdrawal limits for ' . $curr);

my $withdrawal_limits = $client->get_withdrawal_limits();

print '<p style="font-weight:bold; text-align:center;">CLIENT ACCOUNT BALANCE</p>'
    . 'Client account balance is <b>'
    . $curr . ' '
    . $bal . '</b>' . '<hr>'
    . '<p style="font-weight:bold; text-align:center;">MAXIMUM WITHDRAWALS ALLOWED</p>' . '<ul>'
    . '<li>MAXIMUM WITHDRAWAL TO IRREVOCABLE METHODS : <b>'
    . $curr . ' '
    . $withdrawal_limits->{'max_withdrawal'}
    . '</b></li>' . '</ul>';

code_exit_BO();

