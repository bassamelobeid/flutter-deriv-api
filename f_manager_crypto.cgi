#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Client::Account;
use Date::Utility;
use Format::Util::Numbers qw/financialrounding formatnumber/;
use JSON::XS;
use HTML::Entities;
use List::UtilsBy qw(rev_nsort_by sort_by);
use POSIX ();
use Postgres::FeedDB::CurrencyConverter qw(in_USD);
use YAML::XS;

use Bitcoin::RPC::Client;
use Ethereum::RPC::Client;

use BOM::Backoffice::Auth0;
use BOM::Backoffice::PlackHelpers qw/PrintContentType_excel PrintContentType/;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use BOM::CTC::Reconciliation;
use BOM::Database::ClientDB;
use BOM::DualControl;
use f_brokerincludeall;

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('CRYPTO CASHIER MANAGEMENT');

my $broker = request()->broker_code;
my $staff  = BOM::Backoffice::Auth0::from_cookie()->{nickname};
# Currency is utilised in Deposit and Withdrawal views accordingly
# to distinguish information among supported cryptocurrencies.
my $currency = request()->param('currency') // 'BTC';
# Action is used for transaction verification purposes.
my $action = request()->param('action');
# Address is retrieved from Search view for `Address` option.
my $address = request()->param('address');
# Show new addresses in recon?
my $show_new_addresses = request()->param('include_new');
# view type is a filter option which is used to sort transactions
# based on their status:it might be either pending, verified, rejected,
# processing,performing_blockchain_txn, sent or error.
# Accessable on Withdrawal action only. By defaullt Withdrawal page
# shows `pending` transactions.
my $view_type = request()->param('view_type') // 'pending';
# Currently, the controller renders page according to Deposit,
# Withdrawal and Search actions.
my $view_action = request()->param('view_action') // '';

code_exit_BO("Invalid currency.")
    if $currency !~ /^[A-Z]{3}$/;

my $cfg = YAML::XS::LoadFile('/etc/rmg/cryptocurrency_rpc.yml');

my $currency_url = $cfg->{blockchain_url}{$currency};
code_exit_BO('No currency urls for ' . $currency) unless $currency_url->{transaction} and $currency_url->{address};

my $transaction_uri = URI->new($currency_url->{transaction});
my $address_uri     = URI->new($currency_url->{address});
my $tt              = BOM::Backoffice::Request::template;
{
    my $cmd = request()->param('command');
    $tt->process(
        'backoffice/crypto_cashier/main.tt2',
        {
            rpc_command => $cmd,
            testnet     => BOM::Platform::Config::on_qa() ? 1 : 0
        }) || die $tt->error();
}

## CTC
Bar("Actions");

my $now        = Date::Utility->new;
my $start_date = request()->param('start_date') || POSIX::mktime(0, 0, 0, 1, $now->month - 1, $now->year - 1900);
my $end_date   = request()->param('end_date') || POSIX::mktime(0, 0, 0, 0, $now->month, $now->year - 1900);
try {
    $start_date = Date::Utility->new($start_date);
    $end_date   = Date::Utility->new($end_date);
}
catch {
    code_exit_BO($_);
};

my $clientdb = BOM::Database::ClientDB->new({broker_code => $broker});
my $dbh = $clientdb->db->dbh;

my $rpc_client_builders = {
    BTC => sub { Bitcoin::RPC::Client->new((%{$cfg->{bitcoin}},      timeout => 5)) },
    BCH => sub { Bitcoin::RPC::Client->new((%{$cfg->{bitcoin_cash}}, timeout => 5)) },
    LTC => sub { Bitcoin::RPC::Client->new((%{$cfg->{litecoin}},     timeout => 5)) },
    ETH => sub { Ethereum::RPC::Client->new((%{$cfg->{ethereum}},    timeout => 5)) },
};
my $rpc_client = ($rpc_client_builders->{$currency} // code_exit_BO("no RPC client found for currency " . $currency))->();
# Exchange rate should be populated according to supported cryptocurrencies.

my $exchange_rate = eval { in_USD(1.0, $currency) } or code_exit_BO("no exchange rate found for currency " . $currency . ". Please contact IT.")->();

my $display_transactions = sub {
    my $trxns = shift;
    # Assign USD equivalent value
    for my $trx (@$trxns) {
        $trx->{amount} //= 0;    # it will be undef on newly generated addresses
        $trx->{usd_amount} = formatnumber('amount', 'USD', $trx->{amount} * $exchange_rate);
    }

    # Render template page with transactions
    my $tt = BOM::Backoffice::Request::template;
    $tt->process(
        'backoffice/crypto_cashier/manage_crypto_transactions.tt',
        {
            transactions    => $trxns,
            broker          => $broker,
            currency        => $currency,
            transaction_uri => $transaction_uri,
            address_uri     => $address_uri,
            view_action     => $view_action,
            view_type       => $view_type,
            controller_url  => request()->url_for('backoffice/f_manager_crypto.cgi'),
            testnet         => BOM::Platform::Config::on_qa() ? 1 : 0,
        }) || die $tt->error();
};

my $tt2 = BOM::Backoffice::Request::template;
$tt2->process(
    'backoffice/crypto_cashier/crypto_control_panel.html.tt',
    {
        exchange_rate  => $exchange_rate,
        controller_url => request()->url_for('backoffice/f_manager_crypto.cgi'),
        currency       => $currency,
        cmd            => request()->param('command') // '',
        broker         => $broker,
        start_date     => $start_date->date_yyyymmdd,
        end_date       => $end_date->date_yyyymmdd,
        now            => $now->datetime_ddmmmyy_hhmmss,
        staff          => $staff,
    }) || die $tt2->error();
if ($view_action eq 'withdrawals') {
    Bar("LIST OF TRANSACTIONS - WITHDRAWAL");

    code_exit_BO("Invalid address.")
        if $address and $address !~ /^\w+$/;
    code_exit_BO("Invalid action.")
        if $action and $action !~ /^[a-zA-Z]{4,15}$/;
    code_exit_BO("Invalid selection to view type of transactions.")
        if not $view_type or $view_type !~ /^(?:pending|verified|rejected|processing|performing_blockchain_txn|sent|error)$/;

    if ($action and $action =~ /^(?:verify|reject)$/) {
        my $dcc_code = request()->param('dual_control_code');
        code_exit_BO("ERROR: Please provide valid dual control code")
            unless $dcc_code;

        my $amount  = request()->param('amount');
        my $loginid = request()->param('loginid');

        my $error = BOM::DualControl->new({
                staff           => $staff,
                transactiontype => $address
            })->validate_payment_control_code($dcc_code, $loginid, $currency, $amount);

        code_exit_BO($error->get_mesg()) if $error;

        my $found;
        ($found) = $dbh->selectrow_array('SELECT payment.ctc_set_withdrawal_verified(?, ?)', undef, $address, $currency)
            if $action eq 'verify';
        ($found) = $dbh->selectrow_array('SELECT payment.ctc_set_withdrawal_rejected(?, ?)', undef, $address, $currency)
            if $action eq 'reject';

        code_exit_BO("ERROR: No record found. Please check with someone from IT team before proceeding.")
            unless ($found);
    }

    my $ctc_status = $view_type eq 'pending' ? 'LOCKED' : uc($view_type);
    # Fetch transactions according to filter option
    my $trxns = $dbh->selectall_arrayref(
        "SELECT * FROM payment.ctc_bo_get_withdrawal(NULL, NULL, ?, ?::payment.CTC_STATUS, NULL, NULL)",
        {Slice => {}},
        $currency, $ctc_status
    );
    $display_transactions->($trxns);
} elsif ($view_action eq 'deposits') {
    Bar("LIST OF TRANSACTIONS - DEPOSITS");
    $view_type ||= 'new';
    code_exit_BO("Invalid selection to view type of transactions.") if $view_type !~ /^(?:new|pending|confirmed|error)$/;

    # Fetch all deposit transactions matching specified currency and status
    my $trxns = $dbh->selectall_arrayref(
        "SELECT * FROM payment.ctc_bo_get_deposit(NULL, NULL, ?, ?::payment.CTC_STATUS, NULL, NULL)",
        {Slice => {}},
        $currency, uc $view_type
    );
    $display_transactions->($trxns);

} elsif ($view_action eq 'search') {
    my $search_type  = request()->param('search_type');
    my $search_query = request()->param('search_query');
    Bar("SEARCH RESULT FOR $search_query");

    my @trxns = ();
    code_exit_BO("Invalid type of search request.")
        unless grep { $search_type eq $_ } qw/loginid address/;

    # Fetch all transactions matching specified searching details
    @trxns = (
        @{$dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(NULL, ?, ?)", {Slice => {}}, $search_query, $currency)},
        @{$dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_deposit(NULL, ?, ?)",    {Slice => {}}, $search_query, $currency)},
    ) if ($search_type eq 'address');

    @trxns = (
        @{$dbh->selectall_arrayref('SELECT * FROM payment.ctc_bo_get_withdrawal(?, NULL, ?)', {Slice => {}}, $search_query, $currency)},
        @{$dbh->selectall_arrayref('SELECT * FROM payment.ctc_bo_get_deposit(?, NULL, ?)',    {Slice => {}}, $search_query, $currency)},
    ) if ($search_type eq 'loginid');

    $display_transactions->(\@trxns);

} elsif ($view_action eq 'reconcil') {
    Bar($currency . ' Reconciliation');

    my $clientdb = BOM::Database::ClientDB->new({broker_code => 'CR'});
    my $recon = BOM::CTC::Reconciliation->new(
        currency => $currency,
    );

    # First, we get a mapping from address to database transaction information
    $recon->from_database_items(
        $dbh->selectall_arrayref(
            q{SELECT * FROM payment.ctc_bo_transactions_for_reconciliation(?, ?, ?)},
            {Slice => {}},
            $currency, $start_date->iso8601, $end_date->iso8601
            )
            or die 'failed to run ctc_bo_transactions_for_reconciliation'
    );

    if ($currency eq 'ETH') {
        my $collectordb = BOM::Database::ClientDB->new({
                broker_code => 'FOG',
                operation   => 'collector',
            })->db->dbh;

        if (
            my $deposits = $collectordb->selectall_arrayref(
                q{SELECT * FROM cryptocurrency.bookkeeping WHERE currency_code = ? AND transaction_type = 'deposit' AND DATE_TRUNC('day', tmstmp) >= ? AND DATE_TRUNC('day', tmstmp) <= ?},
                {Slice => {}},
                $currency,
                $start_date->iso8601,
                $end_date->iso8601
            ))
        {
            $recon->from_blockchain_deposits($deposits);
        } else {
            code_exit_BO('<p style="color:red;">Unable to request deposits from RPC</p>');
        }

        if (
            my $withdrawals = $collectordb->selectall_arrayref(
                q{SELECT * FROM cryptocurrency.bookkeeping WHERE currency_code = ? AND transaction_type = 'withdrawal' AND DATE_TRUNC('day', tmstmp) >= ? AND DATE_TRUNC('day', tmstmp) <= ?},
                {Slice => {}},
                $currency,
                $start_date->iso8601,
                $end_date->iso8601
            ))
        {
            $recon->from_blockchain_withdrawals($withdrawals);
        } else {
            code_exit_BO('<p style="color:red;">Unable to request deposits from RPC</p>');
        }
    } else {
        # Apply date filtering. Note that this is currently BTC/BCH/LTC-specific, but
        # once we have the information in the database we should pass the date range
        # as a parameter instead.
        my $filter = sub {
            my ($transactions) = @_;
            my $start_epoch    = $start_date->epoch;
            my $end_epoch      = $end_date->epoch;
            return [grep { (not exists $_->{time}) or ($_->{time} >= $start_epoch and $_->{time} <= $end_epoch) } @$transactions];
        };
        if (my $deposits = $rpc_client->listreceivedbyaddress(0)) {
            $recon->from_blockchain_deposits($filter->($deposits));
        } else {
            code_exit_BO('<p style="color:red;">Unable to request deposits from RPC</p>');
        }
        if (my $withdrawals = $rpc_client->listtransactions('', 10_000)) {
            $recon->from_blockchain_withdrawals($filter->($withdrawals));
        } else {
            code_exit_BO('<p style="color:red;">Unable to request withdrawals from RPC</p>');
        }
    }

    # Go through the complete list of db/blockchain entries to make sure that
    # things are consistent.
    my @recon_list = $recon->reconcile;

    my @hdr = (
        'Client ID', 'Type', $currency . ' Address',
        'Amount', 'Amount USD', 'Status', 'Payment date', 'Blockchain date',
        'Status date', 'Confirmations', 'Transactions',
        'Blockchain transaction ID',
        'DB Payment ID', 'Errors'
    );
    my $filename = join '-', $start_date->date_yyyymmdd, $end_date->date_yyyymmdd, $currency;

    # TODO: move representation logic to template
    print <<"EOF";
<div>
<a download="${filename}.xls" href="#" onclick="return ExcellentExport.excel(this, 'recon_table', '$filename');">Export to Excel</a>
<a download="${filename}.csv" href="#" onclick="return ExcellentExport.csv(this, 'recon_table');">Export to CSV</a>
</div>
EOF
    print '<table id="recon_table" style="width:100%;" border="1" class="sortable"><thead><tr>';
    print '<th scope="col">' . encode_entities($_) . '</th>' for @hdr;
    print '</thead><tbody>';
    # sort_by { $_->{address} } values %db_by_address) {
    TRAN:
    for my $db_tran (@recon_list) {
        next TRAN if $db_tran->is_status_in(qw(NEW MIGRATED)) and not $show_new_addresses;
        print '<tr>';
        print '<td>' . encode_entities($_) . '</td>' for map { $_ // '' } @{$db_tran}{qw(loginid type)};
        print '<td><a href="' . $address_uri . $_ . '" target="_blank">' . encode_entities($_) . '</a></td>' for $db_tran->{address};
        if (defined $db_tran->{amount}) {
            print '<td style="text-align:right;">'
                . encode_entities($_)
                . '</td>'
                for formatnumber(
                'amount',
                $currency,
                financialrounding(
                    price => $currency,
                    $db_tran->{amount})
                ),
                '$'
                . formatnumber(
                amount => 'USD',
                financialrounding(
                    price => 'USD',
                    in_USD($db_tran->{amount}, $currency)));
        } else {
            print '<td>&nbsp;</td><td>&nbsp;</td>';
        }
        print '<td>' . encode_entities($_) . '</td>' for map { $_ // '' } @{$db_tran}{qw(status)};
        print '<td sorttable_customkey="' . (sprintf "%012d", $_ ? Date::Utility->new($_)->epoch : 0) . '">' . encode_entities($_) . '</td>'
            for map { $_ // '' } @{$db_tran}{qw(transaction_date blockchain_date status_date)};
        print '<td><span style="color: ' . ($_ >= 3 ? 'green' : 'gray') . '">' . encode_entities($_) . '</td>'
            for map { $_ // '' } @{$db_tran}{qw(confirmations)};
        print '<td><span style="color: ' . ($_ > 1 ? 'red' : $_ == 1 ? 'green' : 'gray') . '">' . encode_entities($_) . '</td>'
            for map { $_ // 0 } @{$db_tran}{qw(transactions)};
        print '<td>'
            . ($_ ? '<a target="_blank" href="' . ($transaction_uri . $_) . '">' : '')
            . encode_entities(substr $_, 0, 6)
            . ($_ ? '</a>' : '') . '</td>'
            for map { $_ // '' } @{$db_tran}{qw(transaction_id)};
        print '<td>' . ($db_tran->{payment_id} ? encode_entities($db_tran->{payment_id}) : '&nbsp;') . '</td>';
        print '<td style="color:red;">' . (join '<br>', map { encode_entities($_) } @{$db_tran->{comments} || []}) . '</td>';
        print '</tr>';
    }
    print '</tbody></table>';
} elsif ($view_action eq 'run') {
    my $cmd               = request()->param('command');
    my %valid_rpc_command = (
        getbalance           => 1,
        getinfo              => 1,
        getpeerinfo          => 1,
        getnetworkinfo       => 1,
        listaccounts         => 1,
        listtransactions     => 1,
        listaddressgroupings => 1,
    );
    my @param;
    if ($valid_rpc_command{$cmd}) {
        if ($cmd eq 'listtransactions') {
            push @param, '', 500;
        }
        my $rslt = $rpc_client->$cmd(@param);
        if ($cmd eq 'listaccounts') {
            print '<table><thead><tr><th scope="col">Account</th><th scope="col">Amount</th></tr></thead><tbody>';
            for my $k (sort keys %$rslt) {
                my $amount = $rslt->{$k};
                print '<tr><th scope="row">' . encode_entities($k) . '</th><td>' . encode_entities($amount) . '</td></tr>' . "\n";
            }
            print '</table>';
        } elsif ($cmd eq 'getbalance') {
            print 'Current balance: <pre>' . encode_entities($rslt) . '</pre>';
        } elsif ($cmd eq 'listtransactions') {
            my @hdr = ('Account', 'Transaction ID', 'Amount', 'Transaction date', 'Confirmations', 'Address');
            print '<table><thead><tr>';
            print '<th scope="col">' . encode_entities($_) . '</th>' for @hdr;
            print '</tr></thead><tbody>';
            for my $tran (rev_nsort_by { $_->{time} } @$rslt) {
                my @fields = @{$tran}{qw(account txid amount time confirmations address)};
                $_ = Date::Utility->new($_)->datetime_yyyymmdd_hhmmss for $fields[3];
                @fields = map { encode_entities($_) } @fields;
                $_ = '<a target="_blank" href="' . $transaction_uri . $_ . '">' . $_ . '</a>' for $fields[1];
                print '<tr>';
                print '<td>' . $_ . '</td>' for @fields;
                print "</tr>\n";
            }
            print '</tbody></table>';
        } elsif ($cmd eq 'listaddressgroupings') {
            print '<table><thead><tr><th scope="col">Address</th><th scope="col">Account</th><th scope="col">Amount</th></tr></thead><tbody>';
            for my $item (@$rslt) {
                for my $address (@$item) {
                    print '<tr>';
                    $address->[2] = join(',', splice @$address, 2) // '';
                    # Swap address and amount so that the amount is at the end
                    print '<td>' . encode_entities($_) . "</td>\n" for @{$address}[0, 2, 1];
                    print "</tr>\n";
                }
            }
            print '</tbody></table>';
        } else {
            print '<pre>' . encode_entities(JSON::XS->new->allow_blessed->pretty(1)->encode($rslt)) . '</pre>';
        }
    } else {
        die 'Invalid ' . $currency . ' command: ' . $cmd;
    }
} elsif ($view_action eq 'new_deposit_address') {
    my $rslt = $rpc_client->getnewaddress('manual');
    print '<p>New ' . $currency . ' address for deposits: <strong>' . encode_entities($rslt) . '</strong></p>';
} elsif ($view_action eq 'make_dcc') {
    my $amount_dcc  = request()->param('amount_dcc')  // 0;
    my $loginid_dcc = request()->param('loginid_dcc') // '';
    my $transtype   = request()->param('address_dcc') // '';

    Bar('Dual control code');

    code_exit_BO("No address provided")                              unless $transtype;
    code_exit_BO('Invalid loginid')                                  unless $loginid_dcc;
    code_exit_BO("ERROR in amount: " . encode_entities($amount_dcc)) unless $amount_dcc =~ /^\d+\.?\d*$/;

    my $client_dcc = Client::Account::get_instance({'loginid' => uc($loginid_dcc)});
    code_exit_BO("ERROR: " . encode_entities($loginid_dcc) . " does not exist! Perhaps you made a typo?") unless $client_dcc;

    my $code = BOM::DualControl->new({
            staff           => $staff,
            transactiontype => $transtype
        })->payment_control_code($loginid_dcc, $currency, $amount_dcc);

    my $message =
          "The dual control code created by $staff for an amount of "
        . $currency
        . $amount_dcc
        . " (for a "
        . $transtype
        . ") for "
        . $loginid_dcc
        . " is: <b> $code </b>This code is valid for 1 hour (from "
        . $now->datetime_ddmmmyy_hhmmss
        . ") only.";

    print $message;
}
code_exit_BO();
