#!/usr/bin/perl
package main;

#official globals
use strict 'vars';
use open qw[ :encoding(UTF-8) ];
use BOM::Market::Registry;

use f_brokerincludeall;
use BOM::System::Localhost;
use BOM::Platform::Runtime;
use Format::Util::Strings qw( set_selected_item );
use BOM::Backoffice::Auth0;
use BOM::StaffPages;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Market::Registry;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

if (not BOM::Backoffice::Auth0::from_cookie()) {
    PrintContentType();
    BOM::StaffPages->instance->login();
    code_exit_BO();
} else {
    PrintContentType();
}

my $broker = request()->broker_code;

BrokerPresentation('STAFF LOGIN PAGE');

if (BOM::System::Localhost::is_master_server()) {
    print "<table border=0 width=97%><tr><td width=97% bgcolor=#FFFFEE>
        <b><center><font size=+1>YOU ARE ON THE MASTER LIVE SERVER</font>
        <br>This is the server on which to edit most system files (except those that are specifically to do with a specific broker code).
        </b></font></td></tr></table>";
}

print "<center>";

my $allbrokercodes = '<option>' . join("<option>", BOM::Platform::Runtime->instance->broker_codes->all_codes);

my $brokerselection = "Broker code : <select name=broker>" . set_selected_item($broker, $allbrokercodes) . "</select>";

if (request()->param('only')) {
    $brokerselection = "Broker code : <select name=broker><option>" . request()->param('only') . "</select>";
}

my @all_markets = BOM::Market::Registry->instance->all_market_names;

# TRANSaction REPORTS
if (BOM::Backoffice::Auth0::has_authorisation(['CS'])) {
    print qq~
	<table class="GreenDarkCandy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="94%">
		<tbody>
			<tr class="GreenLabel">
				<td class="whitelabel" colspan="2">TRANSACTION REPORTS</td>
			</tr>
			<tr>
				<td align="center" width="50%">
					<p><b>TRANSACTION REPORTS</b></p>
					<form action="~ . request()->url_for('backoffice/f_bo_enquiry.cgi') . qq~" method="get"><font size=2>
						<b>$brokerselection</b>
						&nbsp;<input type="submit" value="TRANSACTION REPORTS">
					</font></form>
				</td>
			</tr>
		</tbody>
	</table>~;
}

# ACCOUNTING REPORTS
if (BOM::Backoffice::Auth0::has_authorisation(['Accounts'])) {
    print qq~
	<table class="GreenDark2Candy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="94%">
		<tbody>
			<tr class="GreenLabel"><td class="whitelabel" colspan="2">ACCOUNTING REPORTS</td></tr>~;
    print qq~
				<tr>
					<td align="center">
						<p><b>ACCOUNTING REPORTS</b></p>
						<form action="~ . request()->url_for('backoffice/f_accountingreports.cgi') . qq~" method="get"><font size=2>
							<b>$brokerselection</b>
							&nbsp;<input type="submit" value="ACCOUNTING REPORTS">
						</font></form>
					</td>
				</tr>~;
    print qq~
		</tbody>
	</table>~;
}

# MANUAL INPUT OF DEPOSITS & WITHDRAWALS
if (BOM::Backoffice::Auth0::has_authorisation(['Payments'])) {
    print qq~
		<table class="GreyCandy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="94%">
			<tbody>
				<tr class="GreyLabel">
					<td class="whitelabel" colspan="2">DEPOSITS & WITHDRAWALS</td>
				</tr>
				<tr>
					<td align="center">
						<p><b>MANUAL INPUT OF DEPOSITS & WITHDRAWALS</b></p>
						<form action="~ . request()->url_for('backoffice/f_manager.cgi') . qq~" method="post"><font size=2>
							<b>$brokerselection</b>
							&nbsp;<input type="submit" value="DEPOSITS & WITHDRAWALS">
						</font></form>
					</td>
				</tr>
			</tbody>
		</table>~;
}

# CLIENT DETAILS RECORDS
if (BOM::Backoffice::Auth0::has_authorisation(['CS'])) {
    print qq~
	<table class="Grey2Candy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="94%">
		<tbody>
			<tr class="GreyLabel">
				<td class="whitelabel" colspan="2">CLIENT MANAGEMENT</td>
			</tr>
			<tr>
				<td align="center" width="50%">
					<p><b>CLIENT DETAILS<br />(Client names, addresses, etc)</b></p>
					<form action="~ . request()->url_for('backoffice/f_clientloginid.cgi') . qq~" method="get"><font size=2>
						<b>$brokerselection</b>
						&nbsp;<input type="submit" value="CLIENT DETAILS">
					</font></form>
				</td>
			</tr>
		</tbody>
	</table>~;
}

# INVESTIGATIVE TOOLS
print qq~
<table class="Grey2Candy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="94%">
	<tbody>
		<tr class="GreyLabel">
			<td class="whitelabel" colspan="2">INVESTIGATIVE TOOLS</td>
		</tr>
		<tr>
			<td align="center" width="50%">
				<p><b>INVESTIGATIVE TOOLS</b></p>
				<form action="~ . request()->url_for('backoffice/f_investigative.cgi') . qq~" method="get"><font size=2>
					<b>CIL :</b> <select name=mycil>
						<option>CS</option>
						<option>IT</option>
						<option>IA</option>
						<option>QUANTS</option>
					</select>
					&nbsp;<b>$brokerselection</b>
					&nbsp;<input type="submit" value="INVESTIGATIVE TOOLS">
				</font></form>
			</td>
		</tr>
	</tbody>
</table>~;

# MARKETING
if (BOM::Backoffice::Auth0::has_authorisation(['Marketing'])) {
    print qq~
	<table class="RedCandy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="94%">
		<tbody>
			<tr class="RedLabel">
				<td class="whitelabel" colspan="2">MARKETING</td>
			</tr>
			<tr>
				<td align="center" width="50%">
					<p><b>MARKETING TOOLS</p>
					<form action="~ . request()->url_for('backoffice/f_promotional.cgi') . qq~" method="get"><font size=2>
						<b>$brokerselection</b>
						&nbsp;<input type="submit" value="MARKETING">
					</font></form>
				</td>
			</tr>
		</tbody>
	</table>~;
}

if (BOM::Backoffice::Auth0::has_authorisation(['Quants'])) {
    print qq~
	<table class="Grey3Candy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="94%">
		<tbody>
			<tr class="GreyLabel">
				<td class="whitelabel" colspan="2">QUANT TOOLS</td>
			</tr>
			<tr>
				<td align="center" colspan="2">
					<p><b>RISK DASHBOARD</b></p>
					<form action="~ . request()->url_for('backoffice/quant/risk_dashboard.cgi') . qq~" method="post"><font size=2>
						<input type="submit" value="RISK DASHBOARD">
					</font></form>
			</tr>
			<tr>
				</td>
				<td align="center" width="50%">
					<p><b>QUANT MARKET DATA</b></p>
					<form action="~ . request()->url_for('backoffice/f_bet_iv.cgi') . qq~" method="post"><font size=2>
						&nbsp;<input type="submit" value="QUANT MARKET DATA">
					</font></form>
				</td>
				<td align="center" width="50%">
					<p><b>CONTRACT SETTLEMENT</b></p>
					<form action="~ . request()->url_for('backoffice/quant/settle_contracts.cgi') . qq~" method="post"><font size=2>
						<b>$brokerselection</b>
						&nbsp;<input type="submit" value="CONTRACT SETTLEMENT">
					</font></form>
				</td>
			</tr>
			<tr>
                               <td align="center" width="50%">
					<p><b>CREATE MANUAL TRANSACTION</b></p>
					<form action="~ . request()->url_for('backoffice/quant/pricing/f_dealer.cgi') . qq~" method="post"><font size=2>
						<b>$brokerselection</b>
						&nbsp;<input type="submit" value="CREATE MANUAL TRANSACTION ">
					</font></form>
				</td>
				<td align="center" width="50%">
					<p><b>BET PRICE OVER TIME</b></p>
					<form action="~ . request()->url_for('backoffice/quant/pricing/bpot.cgi') . qq~" method="post"><font size=2>
						<input type="submit" value="BET PRICE OVER TIME">
					</font></form>
				</td>
                         </tr>
			 <tr>	
                                <td align="center" width="50%">
					<p><b>RETRIEVE CONTRACT DETAILS</b></p>
					<form action="~ . request()->url_for('backoffice/quant/pricing/contract_details.cgi') . qq~" method="post"><font size=2>
						<b>$brokerselection</b>
                                                <input type="submit" value="RETRIEVE CONTRACT DETAILS">
					</font></form>
				</td>

			</tr>
		</tbody>
	</table>~;
}

# REALTIME QUOTES
if (BOM::Backoffice::Auth0::has_authorisation(['Quants'])) {
    print qq~
	<table class="BlueLightCandy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="94%">
		<tbody>
			<tr class="BlueLabel">
				<td class="whitelabel" colspan="2">REALTIME FEEDS</td>
			</tr>
			<tr>
				<td align="center" width="50%">
					<p><b>REALTIME QUOTES<br />(quotes & news feeds gateway)</b></p>
					<form action="~ . request()->url_for('backoffice/f_rtquoteslogin.cgi') . qq~" method="get"><font size=2><b>
						<b>$brokerselection</b>
						&nbsp;<input type="submit" value="REALTIME QUOTES">
					</font></form>
				</td>
			</tr>
		</tbody>
	</table>~;
}

# WEBSITE CUSTOMIZATION
if (BOM::Backoffice::Auth0::has_authorisation(['IT'])) {
    print qq~
	<table class="BlueCandy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="94%">
		<tbody>
			<tr class="BlueLabel">
				<td class="whitelabel" colspan="2">WEBSITE CUSTOMIZATION & SHUTDOWN</td>
			</tr>
			<tr>
				<td align="center">
					<p><b><a name="dynamic_settings">DYNAMIC SETTINGS</a></b></p>
					<form action="~ . request()->url_for('backoffice/f_dynamic_settings.cgi') . qq~" method="get"><font size=2>
                        <b>Group: </b><select name=group>
                            <option value=shutdown_suspend>Shutdown/Suspend</option>
                            <option value=cs>CS</option>
                            <option value=quant>Quant</option>
                            <option value=it>IT</option>
                            <option value=others>Others</option>
                            <option value=payments>Payments</option>
                            <option value=marketing>Marketing</option>
                        </select>
						<input type=hidden name=broker value=FOG>
						<input type=hidden name=page value=global>
						<input type=hidden name=l value=EN>
						&nbsp;<input type="submit" value="DYNAMIC SETTINGS">
					</font></form>
				</td>
			</tr>
		</tbody>
	</table>~;
}

code_exit_BO();

