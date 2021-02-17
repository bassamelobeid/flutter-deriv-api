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
        <div id="live_server_warning" class="notify notify--warning">
            <h3>YOU ARE ON THE MASTER LIVE SERVER</h3>
            <span>This is the server on which to edit most system files (except those that are specifically to do with a specific broker code).</span>
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
    <div class="card">
        <div class="card__label">
            Transaction reports
        </div>
        <div class="card__content">
            <h3>Transaction reports</h3>
            <form action="~ . request()->url_for('backoffice/f_bo_enquiry.cgi') . qq~" method="get">
                <label>$brokerselection</label>
                <input type="submit" class="btn btn--primary" value="Transaction reports">
            </form>
        </div>
    </div>~;
}

# ACCOUNTING REPORTS
if (BOM::Backoffice::Auth0::has_authorisation(['Accounts'])) {
    print qq~
    <div class="card">
        <div class="card__label">
            Accounting reports
        </div>
        <div class="card__content">
            <h3>Accounting reports</h3>
            <form action="~ . request()->url_for('backoffice/f_accountingreports.cgi') . qq~" method="get">
                <label>$brokerselection</label>
                <input type="submit" class="btn btn--primary" value="Accounting reports">
            </form>
        </div>
    </div>~;
}

# MANUAL input OF DEPOSITS & WITHDRAWALS
if (BOM::Backoffice::Auth0::has_authorisation(['Payments'])) {
    print qq~
    <div class="card">
        <div class="card__label">
            Deposits & withdrawals
        </div>
        <div class="card__content">
            <h3>Manual input of deposit & withdrawals</h3>
            <form action="~ . request()->url_for('backoffice/f_manager.cgi') . qq~" method="post">
                <label>$brokerselection</label>
                <input type="submit" class="btn btn--primary" value="Deposits & withdrawals">
            </form>
        </div>
    </div>~;
}

# CLIENT DETAILS RECORDS
if (BOM::Backoffice::Auth0::has_authorisation(['CS'])) {
    print qq~
        <div class="card">
            <div class="card__label">
                Client management
            </div>
            <div class="card__content">
                <h3>Client details (Client names, addresses, etc) </h3>
                <form action="~ . request()->url_for('backoffice/f_clientloginid.cgi') . qq~" method="get">
                    <label>$brokerselection</label>
                    <input type="submit" class="btn btn--primary" value="Client details">
                </form>
            </div>
        </div>
        <div class="card">
            <div class="card__label">
                Contract details
            </div>
            <div class="card__content">
                <h3>Bet price over time</h3>
                <form action="~ . request()->url_for('backoffice/quant/pricing/bpot.cgi', {broker => $broker}) . qq~" method="post">
                    <input type="submit" class="btn btn--primary" value="Bet price over time">
                </form>
            </div>
        </div>~;
}

# INVESTIGATIVE TOOLS
print qq~
<div class="card">
    <div class="card__label">
        Investigative tools
    </div>
    <div class="card__content">
        <h3>Investigative tools</h3>
        <form action="~ . request()->url_for('backoffice/f_investigative.cgi') . qq~" method="get">
            <label>CIL :</label>
            <select name="mycil">
                <option>CS</option>
                <option>IT</option>
                <option>IA</option>
                <option>QUANTS</option>
            </select>
            <label>$brokerselection</label>
            <input type="submit" class="btn btn--primary" value="Investigative tools">
        </form>
    </div>
</div>~;

# App management
if (BOM::Backoffice::Auth0::has_authorisation(['Marketing'])) {
    print qq~
    <div class="card">
        <div class="card__label">
            App management
        </div>
        <div class="card__content">
            <h3>App management</h3>
            <a href="f_app_management.cgi" class="btn btn--primary">Go to app management</a>
        </div>
    </div>~;
}

# MARKETING
if (BOM::Backoffice::Auth0::has_authorisation(['Marketing'])) {
    print qq~
    <div class="card">
        <div class="card__label">
            Marketing
        </div>
        <div class="card__content">
            <h3>Marketing tools</h3>
            <form action="~ . request()->url_for('backoffice/f_promotional.cgi') . qq~" method="get">
                <label>$brokerselection</label>
                <input type="submit" class="btn btn--primary" value="Marketing">
            </form>
        </div>
    </div>~;
}

# P2P
print qq~
    <div class="card">
        <div class="card__label">
            P2P
        </div>
        <div class="card__content grid2col border">~;
my $band_mgt     = BOM::Backoffice::Auth0::has_authorisation(['QuantsWrite']);
my $p2p_settings = BOM::Backoffice::Auth0::has_authorisation(['Quants']) && BOM::Backoffice::Auth0::has_authorisation(['IT']);

if ($band_mgt or $p2p_settings) {
    print qq~
            <div class="card__content">
                <h3>Band configuration</h3>
                <form action="~ . request()->url_for('backoffice/p2p_band_management.cgi') . qq~" method="get">
                    <label>$brokerselection</label>
                    <input type="submit" class="btn btn--primary" value="Go">
                </form>
            </div>~;
    if ($p2p_settings) {
        print qq~
            <div class="card__content">
                <h3>Dynamic settings</h3>
                <form action="~ . request()->url_for('backoffice/p2p_band_management.cgi') . qq~" method="get">
                    <a href="p2p_dynamic_settings.cgi" class="btn btn--primary">Go to P2P dynamic settings</a>
                </form>
            </div>~;
    }
}

print qq~
            <div class="card__content">
                <h3>Search order</h3>
                <form action="~ . request()->url_for('backoffice/p2p_order_list.cgi') . qq~" method="get">
                    <label>$brokerselection</label>
                    <input type="submit" class="btn btn--primary" value="Go">
                </form>
            </div>
            <div class="card__content">
                <h3>Order details/management</h3>
                <form action="~ . request()->url_for('backoffice/p2p_order_manage.cgi') . qq~" method="get">
                    <label>$brokerselection</label>
                    <input type="submit" class="btn btn--primary" value="Go">
                </form>
            </div>
            <div class="card__content">
                <h3>Advertiser management</h3>
                <form action="~ . request()->url_for('backoffice/p2p_advertiser_manage.cgi') . qq~" method="get">
                    <label>$brokerselection</label>
                    <input type="submit" class="btn btn--primary" value="Go">
                </form>
            </div>
            <div class="card__content">
                <!-- for future use -->
            </div>
        </div>
    </div>~;

if (BOM::Backoffice::Auth0::has_authorisation(['Quants'])) {
    print qq~
    <div class="card">
        <div class="card__label">
            Quant tools
        </div>
        <div class="card__content grid2col border">
            <div class="card__content">
                <h3>Risk dashboard test</h3>
                <form action="~ . request()->url_for('backoffice/quant/risk_dashboard.cgi') . qq~" method="post">
                    <input type="submit" class="btn btn--primary" value="Risk dashboard">
                </form>
            </div>
            <div class="card__content">
                <h3>Quants risk management tool</h3>
                <form action="~ . request()->url_for('backoffice/quant/quants_config.cgi') . qq~" method="post">
                    <label>$brokerselection</label>
                    <input type="submit" class="btn btn--primary" value="Go">
                </form>
            </div>
            <div class="card__content">
                <h3>Quant market data</h3>
                <form action="~ . request()->url_for('backoffice/f_bet_iv.cgi') . qq~" method="post">
                    <input type="submit" class="btn btn--primary" value="Quant market data">
                </form>
            </div>
            <div class="card__content">
                <h3>Contract settlement</h3>
                <form action="~ . request()->url_for('backoffice/quant/settle_contracts.cgi') . qq~" method="post">
                    <label>$brokerselection</label>
                    <input type="submit" class="btn btn--primary" value="Contract settlement">
                </form>
            </div>
            <div class="card__content">
                <h3>Create manual transaction</h3>
                <form action="~ . request()->url_for('backoffice/quant/pricing/f_dealer.cgi') . qq~" method="post">
                    <label>$brokerselection</label>
                    <input type="submit" class="btn btn--primary" value="Create manual transaction">
                </form>
            </div>
            <div class="card__content">
                <h3>Bet price over time</h3>
                <form action="~ . request()->url_for('backoffice/quant/pricing/bpot.cgi', {broker => $broker}) . qq~" method="post">
                    <input type="submit" class="btn btn--primary" value="Bet price over time">
                </form>
            </div>
            <div class="card__content">
                <h3>Product management</h3>
                <form action="~ . request()->url_for('backoffice/quant/product_management.cgi') . qq~" method="post">
                    <input type="submit" class="btn btn--primary" value="Product management">
                </form>
            </div>
            <div class="card__content">
                <h3>Internal transfer fees</h3>
                <form action="~ . request()->url_for('backoffice/quant/internal_transfer_fees.cgi') . qq~" method="post">
                    <input type="submit" class="btn btn--primary" value="Internal transfer fees">
                </form>
            </div>
            <div class="card__content">
                <h3>Existing limited clients</h3>
                <form action="~ . request()->url_for('backoffice/quant/client_limit.cgi') . qq~" method="post">
                    <label>$brokerselection</label>
                    <input type="submit" class="btn btn--primary" value="Existing limited clients">
                </form>
            </div>
            <div class="card__content">
                <h3>Multiplier risk management tool</h3>
                <form action="~ . request()->url_for('backoffice/quant/multiplier_risk_management.cgi') . qq~" method="post">
                    <input type="submit" class="btn btn--primary" value="Go">
                </form>
            </div>
        </div>
    </div>~;
}

# WEBSITE CUSTOMIZATION
if (BOM::Backoffice::Auth0::has_authorisation(['IT'])) {
    my $group_select = create_dropdown(
        name          => 'group',
        items         => get_dynamic_settings_list(),
        selected_item => 'shutdown_suspend',
    );
    print qq~
    <div class="card">
        <div class="card__label">
            Website customization & shutdown
        </div>
        <div class="card__content">
            <h3>Dynamic settings</h3>
            <form action="~ . request()->url_for('backoffice/f_dynamic_settings.cgi') . qq~" method="get">
                <label>Group: </label>
                $group_select
                <input type=hidden name=broker value=FOG>
                <input type=hidden name=page value=global>
                <input type=hidden name=l value=EN>
                <input type="submit" class="btn btn--primary" value="Dynamic settings">
            </form>
        </div>
    </div>~;
}

# WEBSITE STATUS
if (BOM::Backoffice::Auth0::has_authorisation(['CSWrite'])) {
    print qq~
    <div class="card">
        <div class="card__label">
            Website status
        </div>
        <div class="card__content">
            <h3>Website status</h3>
            <a href="f_setting_website_status.cgi" class="btn btn--primary">Go to website status page</a>
        </div>
    </div>~;
}

code_exit_BO();
