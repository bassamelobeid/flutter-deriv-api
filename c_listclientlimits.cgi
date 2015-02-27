#!/usr/bin/perl
package main;

use strict 'vars';

use f_brokerincludeall;
use BOM::Database::DataMapper::Account;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();

my $login = request()->param('login');

BrokerPresentation('CLIENT LIMITS FOR ' . $login);
BOM::Platform::Auth0::can_access(['CS']);

my $broker = request()->broker->code;

if ($login !~ /^$broker\d+$/) {
    print 'ERROR : Wrong loginID ' . $login;
    code_exit_BO();
}

# Withdrawal limits
my $client = BOM::Platform::Client::get_instance({'loginid' => $login}) || die "[$0] could not get client for $login";
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

