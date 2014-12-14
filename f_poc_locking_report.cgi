#!/usr/bin/perl
package main;

use strict 'vars';

use f_brokerincludeall;
use BOM::Utility::CurrencyConverter qw(in_USD);
use BOM::Platform::Data::Persistence::DataMapper::Account;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Persistence::DAO::Client;
system_initialize();

PrintContentType();
BrokerPresentation('Accounts subject to PoC locking.');
BOM::Platform::Auth0::can_access(['CS']);

my $broker = request()->param('broker');

my $date             = BOM::Utility::Date->new(request()->param('date'));
my $authenticated    = request()->param('authenticated');
my $lock_cashier     = request()->param('lock_cashier');
my $unwelcome_logins = request()->param('unwelcome_logins');
my $funded           = request()->param('funded');

my $all_currencies = request()->available_currencies;

print q~
<br />
<table border=1 cellpadding=0 cellspacing=0 width=95%>
  <tr>
    <th>LOGINID</th>
    <th>DATE JOINED</th>
    <th>NAME</th>
    <th>COUNTRY</th>
    <th>EMAIL</th>
  </tr>
~;

my $frmid     = 1;
my $login_ids = BOM::Platform::Persistence::DAO::Client::get_loginids_for_poc_locking_clients_arrayref({
    'broker'           => $broker,
    'date'             => $date,
    'authenticated'    => $authenticated,
    'lock_cashier'     => $lock_cashier,
    'unwelcome_logins' => $unwelcome_logins,
});

foreach my $loginID (@{$login_ids}) {
    my $client = BOM::Platform::Client::get_instance({'loginid' => $loginID}) || next;

    my $account_mapper = BOM::Platform::Data::Persistence::DataMapper::Account->new({
        client_loginid => $loginID,
        currency_code  => $client->currency,
        operation      => 'read_binary_replica',
    });
    my $bal = in_USD($account_mapper->get_balance(), $client->currency);

    my $client_name  = $client->salutation . ' ' . $client->first_name . ' ' . $client->last_name;
    my $client_email = $client->email;
    my $national     = Locale::Country::code2country($client->citizen);
    my $date_joined  = $client->date_joined;

    if ($funded ne 'any') {
        next if $funded eq 'yes' and $bal <= 0;
        next if $funded eq 'no'  and $bal > 0;
    }

    print qq~
  <tr>
    <td>
      <form name="frm_monitor$frmid" id="frm_monitor$frmid" target="$loginID" action="~
        . request()->url_for('backoffice/f_manager_history.cgi') . qq~" method="post">
        <input name=loginID type=hidden value=$loginID>
        <input type=hidden name=broker value=$broker>
        <input type=hidden name=currency value=USD>
        <input type=hidden name=l value=EN>
        <a href="javascript:document.frm_monitor$frmid.submit();">$loginID</a>
      </form>
    </td>
    <td>$date_joined</td>
    <td>$client_name &nbsp;</td>
    <td>$national &nbsp;</td>
    <td><font size=1>$client_email &nbsp;</font></td>
  </tr>
~;
    $frmid++;
}

print q~
</table>
~;

code_exit_BO();
