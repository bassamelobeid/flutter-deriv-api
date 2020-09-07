#!/etc/rmg/bin/perl
package main;

#official globals
use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use Finance::Asset::Market::Registry;

use f_brokerincludeall;
use BOM::Config;
use BOM::Config::Runtime;
use BOM::Backoffice::Auth0;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use LandingCompany;

use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

# Check if a staff is logged in
BOM::Backoffice::Auth0::get_staff();
PrintContentType();

my $broker = request()->broker_code;

BrokerPresentation('STAFF LOGIN PAGE');

if ((grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}}) && !BOM::Config::on_qa()) {
    print qq~
        <div id="live_server_warning">
            <h1>YOU ARE ON THE MASTER LIVE SERVER</h1>
            This is the server on which to edit most system files (except those that are specifically to do with a specific broker code).
        </div>~;
}

my $brokerselection = 'Broker code : '
    . create_dropdown(
    name          => 'broker',
    items         => [request()->param('only') || LandingCompany::Registry::all_broker_codes],
    selected_item => $broker,
    );

# TRANSACTION REPORTS
if (BOM::Backoffice::Auth0::has_authorisation(['CS'])) {
    print qq~
    <table class="container GreenDarkCandy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="100%">
        <tbody>
            <tr class="GreenLabel">
                <td class="whitelabel" colspan="2">TRANSACTION REPORTS</td>
            </tr>
            <tr>
                <td align="center" width="50%">
                    <div class="section-title">TRANSACTION REPORTS</div>
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
    <table class="container GreenDark2Candy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="100%">
        <tbody>
            <tr class="GreenLabel">
                <td class="whitelabel" colspan="2">ACCOUNTING REPORTS</td>
            </tr>
            <tr>
                <td align="center">
                    <div class="section-title">ACCOUNTING REPORTS</div>
                    <form action="~ . request()->url_for('backoffice/f_accountingreports.cgi') . qq~" method="get"><font size=2>
                        <b>$brokerselection</b>
                        &nbsp;<input type="submit" value="ACCOUNTING REPORTS">
                    </font></form>
                </td>
            </tr>
        </tbody>
    </table>~;
}

# MANUAL INPUT OF DEPOSITS & WITHDRAWALS
if (BOM::Backoffice::Auth0::has_authorisation(['Payments'])) {
    print qq~
        <table class="container GreyCandy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="100%">
            <tbody>
                <tr class="GreyLabel">
                    <td class="whitelabel" colspan="2">DEPOSITS & WITHDRAWALS</td>
                </tr>
                <tr>
                    <td align="center">
                        <div class="section-title">MANUAL INPUT OF DEPOSITS & WITHDRAWALS</div>
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
    <table class="container Grey2Candy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="100%">
        <tbody>
            <tr class="GreyLabel">
                <td class="whitelabel">CLIENT MANAGEMENT</td>
                <td class="whitelabel">CONTRACT DETAILS</td>
            </tr>
            <tr>
                <td align="center" width="50%">
                    <div class="section-title">CLIENT DETAILS<br />(Client names, addresses, etc)</div>
                    <form action="~ . request()->url_for('backoffice/f_clientloginid.cgi') . qq~" method="get"><font size=2>
                        <b>$brokerselection</b>
                        &nbsp;<input type="submit" value="CLIENT DETAILS">
                    </font></form>
                </td>
                <td align="center" width="50%">
                    <div class="section-title">BET PRICE OVER TIME</div>
                    <form action="~ . request()->url_for('backoffice/quant/pricing/bpot.cgi', {broker => $broker}) . qq~" method="post"><font size=2>
                        <input type="submit" value="BET PRICE OVER TIME">
                    </font></form>
                </td>
            </tr>
        </tbody>
    </table>~;
}

# INVESTIGATIVE TOOLS
print qq~
<table class="container Grey2Candy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="100%">
    <tbody>
        <tr class="GreyLabel">
            <td class="whitelabel" colspan="2">INVESTIGATIVE TOOLS</td>
        </tr>
        <tr>
            <td align="center" width="50%">
                <div class="section-title">INVESTIGATIVE TOOLS</div>
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

# App management
if (BOM::Backoffice::Auth0::has_authorisation(['Marketing'])) {
    print qq~
        <table class="container Grey2Candy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="100%">
            <tbody>
                <tr class="GreyLabel">
                    <td class="whitelabel" colspan="2">App management</td>
                </tr>
                <tr>
                    <td align="center" width="50%">
                        <div class="section-title">App management</div>
                        <a href="f_app_management.cgi">Go to app management</a>
                    </td>
                </tr>
            </tbody>
        </table>~;
}

# MARKETING
if (BOM::Backoffice::Auth0::has_authorisation(['Marketing'])) {
    print qq~
    <table class="container RedCandy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="100%">
        <tbody>
            <tr class="RedLabel">
                <td class="whitelabel" colspan="2">MARKETING</td>
            </tr>
            <tr>
                <td align="center" width="50%">
                    <div class="section-title">MARKETING TOOLS</div>
                    <form action="~ . request()->url_for('backoffice/f_promotional.cgi') . qq~" method="get"><font size=2>
                        <b>$brokerselection</b>
                        &nbsp;<input type="submit" value="MARKETING">
                    </font></form>
                </td>
            </tr>
        </tbody>
    </table>~;
}

# P2P
print qq~
    <table class="container GreyCandy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="100%">
        <tbody>
            <tr class="GreenLabel">
                <td class="whitelabel" colspan="2">P2P</td>
            </tr>~;

my $band_mgt     = BOM::Backoffice::Auth0::has_authorisation(['QuantsWrite']);
my $p2p_settings = BOM::Backoffice::Auth0::has_authorisation(['Quants']) && BOM::Backoffice::Auth0::has_authorisation(['IT']);

if ($band_mgt or $p2p_settings) {
    print qq~
            <tr>
                <td align="center" width="50%">~;
    if ($band_mgt) {
        print qq~
                    <div class="section-title">BAND CONFIGURATION</div>
                    <form action="~ . request()->url_for('backoffice/p2p_band_management.cgi') . qq~" method="get"><font size=2>
                        <b>$brokerselection</b>
                        &nbsp;<input type="submit" value="GO">
                    </font></form>~;
    }
    print qq~
                </td>
                <td align="center" valign="top" width="50%">~;
    if ($p2p_settings) {
        print qq~
                    <div class="section-title">DYNAMIC SETTINGS</div>
                    <a href="p2p_dynamic_settings.cgi">Go to P2P dynamic settings</a>~;
    }
    print qq~
                </td>
            </tr>~;
}
print qq~
            <tr>
                <td align="center" width="50%">
                    <div class="section-title">SEARCH ORDER</div>
                    <form action="~ . request()->url_for('backoffice/p2p_order_list.cgi') . qq~" method="get"><font size="2">
                        <b>$brokerselection</b>
                        &nbsp;<input type="submit" value="GO">
                    </font></form>
                </td>
                <td align="center" width="50%">
                    <div class="section-title">ORDER DETAILS/MANAGEMENT</div>
                    <form action="~ . request()->url_for('backoffice/p2p_order_manage.cgi') . qq~" method="get"><font size="2">
                        <b>$brokerselection</b>
                        &nbsp;<input type="submit" value="GO">
                    </font></form>
                </td>
            </tr>
            <tr>
                <td align="center" width="50%">
                    <div class="section-title">ADVERTISER MANAGEMENT</div>
                    <form action="~ . request()->url_for('backoffice/p2p_advertiser_manage.cgi') . qq~" method="get"><font size="2">
                        <b>$brokerselection</b>
                        &nbsp;<input type="submit" value="GO">
                    </font></form>
                </td>
                <td align="center" width="50%">
                    <!-- for future use -->
                </td>
            </tr>
        </tbody>
    </table>~;

if (BOM::Backoffice::Auth0::has_authorisation(['Quants'])) {
    print qq~
    <table class="container Grey3Candy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="100%">
        <tbody>
            <tr class="GreyLabel">
                <td class="whitelabel" colspan="2">QUANT TOOLS</td>
            </tr>
            <tr>
                <td align="center">
                    <div class="section-title">RISK DASHBOARD test</div>
                    <form action="~ . request()->url_for('backoffice/quant/risk_dashboard.cgi') . qq~" method="post"><font size="2">
                        <input type="submit" value="RISK DASHBOARD">
                    </font></form>
                </td>
                <td align="center" width="50%">
                    <div class="section-title">QUANTS RISK MANAGEMENT TOOL</div>
                    <form action="~ . request()->url_for('backoffice/quant/quants_config.cgi') . qq~" method="post"><font size=2>
                        <b>$brokerselection</b>
                        &nbsp;<input type="submit" value="GO">
                    </font></form>
                </td>
            </tr>
            <tr>
                <td align="center" width="50%">
                    <div class="section-title">QUANT MARKET DATA</div>
                    <form action="~ . request()->url_for('backoffice/f_bet_iv.cgi') . qq~" method="post"><font size=2>
                        &nbsp;<input type="submit" value="QUANT MARKET DATA">
                    </font></form>
                </td>
                <td align="center" width="50%">
                    <div class="section-title">CONTRACT SETTLEMENT</div>
                    <form action="~ . request()->url_for('backoffice/quant/settle_contracts.cgi') . qq~" method="post"><font size=2>
                        <b>$brokerselection</b>
                        &nbsp;<input type="submit" value="CONTRACT SETTLEMENT">
                    </font></form>
                </td>
            </tr>
            <tr>
                <td align="center" width="50%">
                    <div class="section-title">CREATE MANUAL TRANSACTION</div>
                    <form action="~ . request()->url_for('backoffice/quant/pricing/f_dealer.cgi') . qq~" method="post"><font size=2>
                        <b>$brokerselection</b>
                        &nbsp;<input type="submit" value="CREATE MANUAL TRANSACTION ">
                    </font></form>
                </td>
                <td align="center" width="50%">
                    <div class="section-title">BET PRICE OVER TIME</div>
                    <form action="~ . request()->url_for('backoffice/quant/pricing/bpot.cgi', {broker => $broker}) . qq~" method="post"><font size=2>
                        <input type="submit" value="BET PRICE OVER TIME">
                    </font></form>
                </td>
            </tr>
            <tr>
                <td align="center" width="50%">
                    <div class="section-title">PRODUCT MANAGEMENT</div>
                    <form action="~ . request()->url_for('backoffice/quant/product_management.cgi') . qq~" method="post"><font size=2>
                        <input type="submit" value="PRODUCT MANAGEMENT">
                    </font></form>
                </td>
                <td align="center" width="50%">
                    <div class="section-title">INTERNAL TRANSFER FEES</div>
                    <form action="~ . request()->url_for('backoffice/quant/internal_transfer_fees.cgi') . qq~" method="post"><font size=2>
                        <input type="submit" value="INTERNAL TRANSFER FEES">
                    </font></form>
                </td>
            </tr>
            <tr>
                <td align="center" width="50%">
                    <div class="section-title">EXISTING LIMITED CLIENTS</div>
                    <form action="~ . request()->url_for('backoffice/quant/client_limit.cgi') . qq~" method="post"><font size=2>
                        <b>$brokerselection</b>
                        &nbsp;<input type="submit" value="EXISTING LIMITED CLIENTS">
                    </font></form>
                </td>
                <td align="center" width="50%">
                    <div class="section-title">MULTIPLIER RISK MANAGEMENT TOOL</div>
                    <form action="~ . request()->url_for('backoffice/quant/multiplier_risk_management.cgi') . qq~" method="post"><font size=2>
                        &nbsp;<input type="submit" value="GO">
                    </font></form>
                </td>
            </tr>
        </tbody>
    </table>~;
}

# WEBSITE CUSTOMIZATION
if (BOM::Backoffice::Auth0::has_authorisation(['IT'])) {
    my $group_select = create_dropdown(
        name          => 'group',
        items         => get_dynamic_settings_list(),
        selected_item => 'shutdown_suspend',
    );
    print qq~
    <table class="container BlueCandy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="100%">
        <tbody>
            <tr class="BlueLabel">
                <td class="whitelabel" colspan="2">WEBSITE CUSTOMIZATION & SHUTDOWN</td>
            </tr>
            <tr>
                <td align="center">
                    <div class="section-title"><a name="dynamic_settings"></a>DYNAMIC SETTINGS</div>
                    <form action="~ . request()->url_for('backoffice/f_dynamic_settings.cgi') . qq~" method="get"><font size=2>
                        <b>Group: </b>
                        $group_select
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

# WEBSITE STATUS
if (BOM::Backoffice::Auth0::has_authorisation(['CSWrite'])) {
    print qq~
    <table class="container Grey2Candy" rules="all" frame="void" border="1" cellpadding="1" cellspacing="2" width="100%">
        <tbody>
            <tr class="GreyLabel">
                <td class="whitelabel" colspan="2">WEBSITE STATUS</td>
            </tr>
            <tr>
                <td align="center" width="50%">
                    <div class="section-title">Website Status</div>
                    <a href="f_setting_website_status.cgi">Go to website status page</a>
                </td>
            </tr>
        </tbody>
    </table>~;
}

print "<style>table.container td:not(.whitelabel) { padding: 5px; }</style>";

code_exit_BO();
