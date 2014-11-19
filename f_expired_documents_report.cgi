#!/usr/bin/perl
package main;

use strict 'vars';

use BOM::Platform::Plack qw( PrintContentType );
use f_brokerincludeall;
system_initialize();

PrintContentType();
BrokerPresentation('Clients who are authenticated but have expired identity documents.');
BOM::Platform::Auth0::can_access(['CS']);

my $broker = request()->param('broker');

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

my $date      = BOM::Utility::Date->new(request()->param('date'));
my $frmid     = 1;
my $login_ids = Persistence::DAO::ClientDAO::get_loginids_for_clients_with_expired_documents_arrayref({
        'broker' => $broker,
        'date'   => $date,
});

foreach my $loginID (@{$login_ids}) {
    my $client = BOM::Platform::Client::get_instance({'loginid' => $loginID}) || next;

    my $client_name  = $client->salutation . ' ' . $client->first_name . ' ' . $client->last_name;
    my $client_email = $client->email;
    my $national     = Locale::Country::code2country($client->citizen);
    my $date_joined  = $client->date_joined;

    print qq~
  <tr>
    <td>
      <form name="frm_monitor$frmid" id="frm_monitor$frmid" target="$loginID" action="~
      . request()->url_for('backoffice/f_manager_history.cgi') . qq~" method="post">
        <input name=loginID type=hidden value=$loginID>
        <input type=hidden name=broker value=$broker>
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
