#!/usr/bin/perl
package main;

use strict 'vars';

use BOM::Platform::Plack qw( PrintContentType );
use f_brokerincludeall;
system_initialize();

PrintContentType();
BrokerPresentation('Client self exclusion report');
BOM::Platform::Auth0::can_access(['CS']);

my $broker = request()->param('broker');

my $all_clients_self_exclusion_hashref = BOM::Platform::Persistence::DAO::Client::get_all_self_exclusion_hashref_by_broker($broker);

my $head = '<tr>';
$head .= '<th>LoginID</th>';
$head .= '<th>Max Open Position</th>';
$head .= '<th>Daily Turnover Limit</th>';
$head .= '<th>Max Cash Balance</th>';
$head .= '<th>Exclude Until</th>';
$head .= '<th>Session Duration</th>';
$head .= '<th>Last Modified Date</th>';
$head .= '</tr>';
my $rows;

foreach my $login_id (keys %{$all_clients_self_exclusion_hashref}) {
    $rows .= "<tr>";

    $rows .= "<td>$all_clients_self_exclusion_hashref->{$login_id}->{'client_loginid'}</td>";
    $rows .= "<td>$all_clients_self_exclusion_hashref->{$login_id}->{'max_open_bets'}</td>";
    $rows .= "<td>$all_clients_self_exclusion_hashref->{$login_id}->{'max_turnover'}</td>";
    $rows .= "<td>$all_clients_self_exclusion_hashref->{$login_id}->{'max_balance'}</td>";
    $rows .= "<td>$all_clients_self_exclusion_hashref->{$login_id}->{'exclude_until'}</td>";
    $rows .= "<td>$all_clients_self_exclusion_hashref->{$login_id}->{'session_duration_limit'}</td>";
    $rows .= "<td>$all_clients_self_exclusion_hashref->{$login_id}->{'last_modified_date'}</td>";

    $rows .= "</tr>";
}

Bar('Client self exclusion report');

print '<table border="1" cellspacing="1" cellpadding="1">';
print $head;
print $rows;
print '</table>';

