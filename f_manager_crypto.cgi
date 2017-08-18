#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use YAML::XS;
use Text::CSV;
use Data::Dumper;
use Date::Utility;
use HTML::Entities;
use Bitcoin::RPC::Client;
use List::UtilsBy qw(rev_nsort_by sort_by);
use Format::Util::Numbers qw/financialrounding formatnumber/;

use Postgres::FeedDB::CurrencyConverter qw(in_USD);
use Client::Account;

use BOM::CTC::Reconciliation;

use BOM::DualControl;
use BOM::Database::ClientDB;
use BOM::Backoffice::Auth0;
use BOM::Backoffice::PlackHelpers qw/PrintContentType_excel PrintContentType/;
use f_brokerincludeall;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('CRYPTO CASHIER MANAGEMENT');

BOM::Backoffice::Auth0::can_access(['Payments']);

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
# Shortcuts for view action commands to prevent descriptive submit text in template
my %va_cmds = (
    withdrawals         => 'Withdrawal Transactions',
    deposits            => 'Deposit Transactions',
    search              => 'Search',
    run                 => 'Run',
    new_deposit_address => 'Get New Deposit Address',
    reconcil            => 'Reconciliation',
    make_dcc            => 'Make Dual Control Code',
);
# Currently, the controller renders page according to Deposit,
# Withdrawal and Search actions.
my $view_action = request()->param('view_action') // '';
# Assign descriptive message if comes from view_type filtering or
# unless it is already.
$view_action = $va_cmds{$view_action} // '' unless grep { $va_cmds{$_} eq $view_action } keys %va_cmds;

if (length($broker) < 2) {
    print
        "We cannot process your request because it would seem that your browser is not configured to accept cookies.  Please check that the 'enable cookies' function is set if your browser, then please try again.";
    code_exit_BO();
}

my %blockchain_transaction_url = (
    BTC => sub { URI->new(BOM::Platform::Config::on_qa() ? 'https://www.blocktrail.com/tBTC/tx/' : 'https://blockchain.info/tx/'); },
    LTC => sub { URI->new(BOM::Platform::Config::on_qa() ? 'https://chain.so/tx/LTCTEST/'        : 'https://live.blockcypher.com/ltc/tx/'); },
);
my %blockchain_address_url = (
    BTC => sub { URI->new(BOM::Platform::Config::on_qa() ? 'https://www.blocktrail.com/tBTC/address/' : 'https://blockchain.info/address/') },
    LTC => sub { URI->new(BOM::Platform::Config::on_qa() ? 'https://chain.so/address/LTCTEST/'        : 'https://live.blockcypher.com/ltc/address/') },
);
my $transaction_uri = URI->new($blockchain_transaction_url{$currency}->());
my $address_uri     = URI->new($blockchain_address_url{$currency}->());
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

use POSIX ();
my $now = Date::Utility->new;
my $start_date = request()->param('start_date') || Date::Utility->new(POSIX::mktime 0, 0, 0, 1, $now->month - 1, $now->year - 1900);
$start_date = Date::Utility->new($start_date) unless ref $start_date;
my $end_date = request()->param('end_date') || Date::Utility->new(POSIX::mktime 0, 0, 0, 0, $now->month, $now->year - 1900);
$end_date = Date::Utility->new($end_date) unless ref $end_date;

# Exchange rate should be populated according to supported cryptocurrencies.
my %exchange_rates = map { $_ => in_USD(1.0, $_) } qw/BTC LTC ETH/;
my $tt2 = BOM::Backoffice::Request::template;
$tt2->process(
    'backoffice/account/crypto_control_panel.html.tt',
    {
        exchange_rates => \%exchange_rates,
        controller_url => request()->url_for('backoffice/f_manager_crypto.cgi'),
        cmd            => request()->param('command') // '',
        broker         => $broker,
        start_date     => $start_date->date_yyyymmdd,
        end_date       => $end_date->date_yyyymmdd,
        now            => $now->datetime_ddmmmyy_hhmmss,
        staff          => $staff,
    }) || die $tt2->error();

code_exit_BO() unless ($view_action);

if (not $currency or $currency !~ /^[A-Z]{3}$/) {
    print "Invalid currency.";
    code_exit_BO();
}

my $clientdb = BOM::Database::ClientDB->new({broker_code => $broker});
my $dbh = $clientdb->db->dbh;

my $cfg = YAML::XS::LoadFile('/etc/rmg/cryptocurrency_rpc.yml');

my %clients = (
    BTC => sub { Bitcoin::RPC::Client->new((%{$cfg->{bitcoin}}, timeout => 5)) },
    LTC => sub { Bitcoin::RPC::Client->new((%{$cfg->{litecoin}}, timeout => 5)) },
    ETH => sub { ... },
);
my $rpc_client = ($clients{$currency} // die "no RPC client found for currency " . $currency)->();

# collect list of transactions and render in template.
if (grep { $view_action eq $va_cmds{$_} } qw/withdrawals deposits search/) {
    my $trxns;
    if ($view_action eq $va_cmds{withdrawals}) {
        Bar("LIST OF TRANSACTIONS - WITHDRAWAL");

        if ($address and $address !~ /^\w+$/) {
            print "Invalid address.";
            code_exit_BO();
        }
        if ($action and $action !~ /^[a-zA-Z]{4,15}$/) {
            print "Invalid action.";
            code_exit_BO();
        }
        if (not $view_type or $view_type !~ /^(?:pending|verified|rejected|processing|performing_blockchain_txn|sent|error)$/) {
            print "Invalid selection to view type of transactions.";
            code_exit_BO();
        }

        my $found;
        if ($action and $action =~ /^(?:verify|reject)$/) {
            my $dcc_code = request()->param('dual_control_code');
            unless ($dcc_code) {
                print "ERROR: Please provide valid dual control code";
                code_exit_BO();
            }

            my $amount  = request()->param('amount');
            my $loginid = request()->param('loginid');

            my $error = BOM::DualControl->new({
                    staff           => $staff,
                    transactiontype => $address
                })->validate_payment_control_code($dcc_code, $loginid, $currency, $amount);
            if ($error) {
                print $error->get_mesg();
                code_exit_BO();
            }

            if ($action eq 'verify') {
                ($found) = $dbh->selectrow_array('SELECT payment.ctc_set_withdrawal_verified(?, ?)', undef, $address, $currency);
                unless ($found) {
                    print "ERROR: No record found. Please check with someone from IT team before proceeding.";
                    code_exit_BO();
                }
            }
            if ($action eq 'reject') {
                ($found) = $dbh->selectrow_array('SELECT payment.ctc_set_withdrawal_rejected(?, ?)', undef, $address, $currency);
                unless ($found) {
                    print "ERROR: No record found. Please check with someone from IT team before proceeding.";
                    code_exit_BO();
                }
            }
        }

        # Fetch transactions according to filter option
        if ($view_type eq 'sent') {
            $trxns = $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(NULL, NULL, ?, 'SENT'::payment.CTC_STATUS, NULL, NULL)",
                {Slice => {}}, $currency);
        } elsif ($view_type eq 'verified') {
            $trxns =
                $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(NULL, NULL, ?, 'VERIFIED'::payment.CTC_STATUS, NULL, NULL)",
                {Slice => {}}, $currency);
        } elsif ($view_type eq 'rejected') {
            $trxns =
                $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(NULL, NULL, ?, 'REJECTED'::payment.CTC_STATUS, NULL, NULL)",
                {Slice => {}}, $currency);
        } elsif ($view_type eq 'processing') {
            $trxns =
                $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(NULL, NULL, ?, 'PROCESSING'::payment.CTC_STATUS, NULL, NULL)",
                {Slice => {}}, $currency);
        } elsif ($view_type eq 'performing_blockchain_txn') {
            $trxns =
                $dbh->selectall_arrayref(
                "SELECT * FROM payment.ctc_bo_get_withdrawal(NULL, NULL, ?, 'PERFORMING_BLOCKCHAIN_TXN'::payment.CTC_STATUS, NULL, NULL)",
                {Slice => {}}, $currency);
        } elsif ($view_type eq 'error') {
            $trxns = $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(NULL, NULL, ?, 'ERROR'::payment.CTC_STATUS, NULL, NULL)",
                {Slice => {}}, $currency);
        } else {
            $trxns = $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(NULL, NULL, ?, 'LOCKED'::payment.CTC_STATUS, NULL, NULL)",
                {Slice => {}}, $currency);
        }
    } elsif ($view_action eq $va_cmds{deposits}) {
        Bar("LIST OF TRANSACTIONS - DEPOSITS");
        if (not $currency or $currency !~ /^[A-Z]{3}$/) {
            print "Invalid currency.";
            code_exit_BO();
        }
        $view_type ||= 'new';
        if (not $view_type or $view_type !~ /^(?:new|pending|confirmed|error)$/) {
            print "Invalid selection to view type of transactions.";
            code_exit_BO();
        }
        # Fetch all deposit transactions matching specified currency and status
        $trxns = $dbh->selectall_arrayref(
            "SELECT * FROM payment.ctc_bo_get_deposit(NULL, NULL, ?, ?::payment.CTC_STATUS, NULL, NULL)",
            {Slice => {}},
            $currency, uc $view_type
        );
    } elsif ($view_action eq $va_cmds{search}) {
        my $search_type  = request()->param('search_type');
        my $search_query = request()->param('search_query');
        Bar("SEARCH RESULT FOR $search_query");

        # Fetch all transactions matching specified searching details
        $trxns = (
            $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_deposit(NULL, ?, NULL, NULL, NULL, NULL)",    {Slice => {}}, $search_query),
            $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(NULL, ?, NULL, NULL, NULL, NULL)", {Slice => {}}, $search_query)
        ) if ($search_type eq 'address');

        $trxns = (
            $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_deposit(?, NULL, NULL, NULL, NULL, NULL)",    {Slice => {}}, $search_query),
            $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(?, NULL, NULL, NULL, NULL, NULL)", {Slice => {}}, $search_query)
        ) if ($search_type eq 'loginid');

        unless (grep { $search_type eq $_ } qw/loginid address/) {
            print "Invalid type of search request.";
            code_exit_BO();
        }
    }
    # Assign USD equivalent value
    $_->{usd_amount} = formatnumber('amount', 'USD', $_->{amount} * $exchange_rates{$_->{currency_code}}) for @$trxns;

    my %reversed = reverse %va_cmds;

    # Render template page with transactions
    my $tt = BOM::Backoffice::Request::template;
    $tt->process(
        'backoffice/account/manage_crypto_transactions.tt',
        {
            transactions    => $trxns,
            broker          => $broker,
            currency        => $currency,
            transaction_uri => $transaction_uri,
            address_uri     => $address_uri,
            view_action     => $reversed{$view_action},
            view_type       => $view_type,
            va_cmds         => \%va_cmds,
            controller_url  => request()->url_for('backoffice/f_manager_crypto.cgi'),
            testnet         => BOM::Platform::Config::on_qa() ? 1 : 0,
        }) || die $tt->error();
} elsif ($view_action eq $va_cmds{reconcil}) {
    Bar($currency . ' Reconciliation');

    if (not $currency or $currency !~ /^[A-Z]{3}$/) {
        print "Invalid currency.";
        code_exit_BO();
    }

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

    if (my $deposits = $rpc_client->listreceivedbyaddress(0)) {
        $recon->from_blockchain_deposits($deposits);
    } else {
        print '<p style="color:red;">Unable to request deposits from RPC</p>';
        code_exit_BO();
    }
    if (my $withdrawals = $rpc_client->listtransactions('', 10_000)) {
        $recon->from_blockchain_withdrawals($withdrawals);
    } else {
        print '<p style="color:red;">Unable to request withdrawals from RPC</p>';
        code_exit_BO();
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
} elsif ($view_action eq $va_cmds{run}) {
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
            print encode_entities(Dumper $rslt);
        }
    } else {
        die 'Invalid ' . $currency . ' command: ' . $cmd;
    }
} elsif ($view_action eq $va_cmds{new_deposit_address}) {
    my $rslt = $rpc_client->getnewaddress('manual');
    print '<p>New ' . $currency . ' address for deposits: <strong>' . encode_entities($rslt) . '</strong></p>';
} elsif ($view_action eq $va_cmds{make_dcc}) {
    my $amount_dcc  = request()->param('amount_dcc')  // 0;
    my $loginid_dcc = request()->param('loginid_dcc') // '';
    my $transtype   = request()->param('address_dcc') // '';

    Bar('Dual control code');
    if (not $transtype) {
        print "No address provided";
        code_exit_BO();
    }

    if (not $amount_dcc or $amount_dcc !~ /^\d*\.?\d*$/) {
        print "ERROR in amount: " . encode_entities($amount_dcc);
        code_exit_BO();
    }

    if (not $loginid_dcc) {
        print 'Invalid loginid';
        code_exit_BO();
    }

    my $client_dcc = Client::Account::get_instance({'loginid' => uc($loginid_dcc)});
    if (not $client_dcc) {
        print "ERROR: " . encode_entities($loginid_dcc) . " does not exist! Perhaps you made a typo?";
        code_exit_BO();
    }

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
