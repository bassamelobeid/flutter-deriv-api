#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use HTML::Entities;

use Bitcoin::RPC::Client;
use Data::Dumper;
use Date::Utility;
use YAML::XS;
use Client::Account;
use Text::CSV;
use List::UtilsBy qw(rev_nsort_by sort_by);
use Format::Util::Numbers qw/financialrounding formatnumber/;

use Postgres::FeedDB::CurrencyConverter qw(in_USD);
use BOM::Database::ClientDB;
use BOM::Backoffice::PlackHelpers qw/PrintContentType_excel PrintContentType/;
use f_brokerincludeall;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('CRYPTO CASHIER MANAGEMENT');

my $broker         = request()->broker_code;
my $encoded_broker = encode_entities($broker);
my $staff          = BOM::Backoffice::Auth0::can_access(['Payments']);
# Currency is utilised in Deposit and Withdrawal views accordingly
# to distinguish information among supported cryptocurrencies.
my $currency = request()->param('currency');
# Action is used for transaction verification purposes.
my $action = request()->param('action');
# Address is retrieved from Search view for `Address` option.
my $address = request()->param('address');
# view type is a filter option which is used to sort transactions
# based on their status:it might be either pending, verified, rejected,
# processing,performing_blockchain_txn, sent or error.
# Accessable on Withdrawal action only. By defaullt Withdrawal page
# shows `pending` transactions.
my $view_type = request()->param('view_type') // 'pending';
# Currently, the controller renders page according to Deposit,
# Withdrawal and Search actions.
my $view_action = request()->param('view_action') // '';
# Shortcuts for view action commands
my %va_cmds = (
    withdrawals         => 'Withdrawal Transactions',
    deposits            => 'Deposit Transactions',
    search              => 'Search',
    run                 => 'Run',
    new_deposit_address => 'Get New Deposit Address',
    reconcil            => 'Reconciliation',
);

if (length($broker) < 2) {
    print
        "We cannot process your request because it would seem that your browser is not configured to accept cookies.  Please check that the 'enable cookies' function is set if your browser, then please try again.";
    code_exit_BO();
}

my $blockchain_uri = URI->new(BOM::Platform::Config::on_qa() ? 'https://www.blocktrail.com/tBTC/tx/' : 'https://blockchain.info/tx/');
my $tt = BOM::Backoffice::Request::template;
{
    my $cmd = request()->param('command');
    $tt->process('backoffice/crypto_cashier/main.tt2', {rpc_command => $cmd}) || die $tt->error();
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
my %exchange_rates;
for (qw/BTC LTC ETH/) {
    $exchange_rates{$_} = in_USD(1.0, $_);
}

my $tt2 = BOM::Backoffice::Request::template;
$tt2->process(
    'backoffice/account/crypto_control_panel.html.tt',
    {
        exchange_rates => \%exchange_rates,
        controller_url => request()->url_for('backoffice/f_manager_crypto.cgi'),
        cmd            => request()->param('command') // '',
        broker         => $encoded_broker,
        start_date     => $start_date->date_yyyymmdd,
        end_date       => $end_date->date_yyyymmdd,
        now            => $now->datetime_ddmmmyy_hhmmss,
    }) || die $tt2->error();

code_exit_BO() unless ($view_action);

my $clientdb = BOM::Database::ClientDB->new({broker_code => $encoded_broker});
my $dbh = $clientdb->db->dbh;

my $cfg = YAML::XS::LoadFile('/etc/rmg/cryptocurrency_rpc.yml');
my $rpc_client = Bitcoin::RPC::Client->new((%{$cfg->{bitcoin}}, timeout => 5));

# collect list of transactions and render in template.
if (grep { $view_action eq $va_cmds{$_} } qw/withdrawals deposits search/) {
    my $trxns;
    if ($view_action eq $va_cmds{withdrawals}) {
        Bar("LIST OF TRANSACTIONS - WITHDRAWAL");
        if (not $currency or $currency !~ /^[A-Z]{3}$/) {
            print "Invalid currency.";
            code_exit_BO();
        }
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
        if ($action and $action eq 'verify') {
            ($found) = $dbh->selectrow_array('SELECT payment.ctc_set_withdrawal_verified(?, ?)', undef, $address, $currency);
            unless ($found) {
                print "ERROR: No record found. Please check with someone from IT team before proceeding.";
                code_exit_BO();
            }
        }
        if ($action and $action eq 'reject') {
            ($found) = $dbh->selectrow_array('SELECT payment.ctc_set_withdrawal_rejected(?, ?)', undef, $address, $currency);
            unless ($found) {
                print "ERROR: No record found. Please check with someone from IT team before proceeding.";
                code_exit_BO();
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
    # Render template page with transactions
    my $tt = BOM::Backoffice::Request::template;
    $tt->process(
        'backoffice/account/manage_crypto_transactions.tt',
        {
            transactions => $trxns,
            broker       => $broker,
            view_type    => $view_type,
            currency     => $currency,
            view_action  => $view_action,
            va_cmds      => \%va_cmds,
        }) || die $tt->error();
} elsif ($view_action eq $va_cmds{reconcil}) {
    Bar('BTC Reconciliation');

    if (not $currency or $currency !~ /^[A-Z]{3}$/) {
        print "Invalid currency.";
        code_exit_BO();
    }

    my $clientdb = BOM::Database::ClientDB->new({broker_code => 'CR'});

    my %db_by_address;
    {    # First, we get a mapping from address to database transaction information
        my $db_transactions = $dbh->selectall_arrayref(
            q{SELECT * FROM payment.ctc_bo_transactions_for_reconciliation(?, ?, ?)},
            {Slice => {}},
            $currency, $start_date->iso8601, $end_date->iso8601
        ) or die 'failed to run ctc_bo_transactions_for_reconciliation';

        for my $db_tran (@$db_transactions) {
            $db_tran->{type} = delete $db_tran->{transaction_type};
            push @{$db_tran->{comments}}, 'Duplicate entries found in DB' if exists $db_by_address{$db_tran->{address}};
            push @{$db_tran->{comments}}, 'Invalid entry - no amount in database'
                unless length($db_tran->{amount} // '')
                or $db_tran->{status} eq 'NEW';
            $db_by_address{$db_tran->{address}} = $db_tran;
        }
    }

    {    # Next, we retrieve all blockchain information relating to deposits
        my $blockchain_transactions = $rpc_client->listreceivedbyaddress(0) or do {
            print '<p style="color:red;">Unable to request transactions from RPC</p>';
            code_exit_BO();
        };
        for my $blockchain_tran (sort_by { $_->{address} } @$blockchain_transactions) {
            my $address = $blockchain_tran->{address};
            my $db_tran = $db_by_address{$address} or do {
                # TODO This should filter by prefix, not just ignore when we have a prefix!
                $db_by_address{$address} = {
                    address             => $address,
                    type                => 'deposit',
                    found_in_blockchain => 1,
                    amount              => $blockchain_tran->{amount},
                    confirmations       => $blockchain_tran->{confirmations},
                    comments            => ['Deposit not found in database']};
                next;
            };
            $db_tran->{found_in_blockchain} = 1;
            if ($db_tran->{type} ne 'deposit') {
                push @{$db_tran->{comments}}, 'Expected deposit, found ' . $db_tran->{type};
            }

            if (
                financialrounding(
                    price => $currency,
                    $blockchain_tran->{amount}
                ) != $db_tran->{amount})
            {
                push @{$db_tran->{comments}}, 'Amount does not match - blockchain ' . $blockchain_tran->{amount} . ', db ' . $db_tran->{amount};
            }
            $db_tran->{confirmations} = $blockchain_tran->{confirmations};
            if (Date::Utility->new($db_tran->{date})->epoch < time - 2 * 120) {
                if ($blockchain_tran->{confirmations} < 3 and not($db_tran->{status} eq 'PENDING' or $db_tran->{status} eq 'NEW')) {
                    push @{$db_tran->{comments}}, 'Invalid status - should be new or pending';
                } elsif ($blockchain_tran->{confirmations} >= 3 and not($db_tran->{status} eq 'CONFIRMED')) {
                    push @{$db_tran->{comments}}, 'Invalid status - should be confirmed';
                }
            }
            if (@{$blockchain_tran->{txids}} > 1) {
                push @{$db_tran->{comments}}, 'Multiple transactions seen';
            }
            $db_tran->{transaction_id} = $blockchain_tran->{txids}[0];
        }
    }

    {    # Now we check for withdrawals
        my $blockchain_transactions = $rpc_client->listtransactions('', 1000) or do {
            print '<p style="color:red;">Unable to request transactions from RPC</p>';
            code_exit_BO();
        };
        for my $blockchain_tran (sort_by { $_->{address} } @$blockchain_transactions) {
            my $address = $blockchain_tran->{address};
            my $db_tran = $db_by_address{$address} or do {
                # TODO This should filter by prefix, not just ignore when we have a prefix!
                $db_by_address{$address} = {
                    address             => $address,
                    type                => 'withdrawal',
                    found_in_blockchain => 1,
                    amount              => $blockchain_tran->{amount},
                    confirmations       => $blockchain_tran->{confirmations},
                    comments            => ['Withdrawal not found in database']};
                next;
            };
            $db_tran->{type}                = 'withdrawal';
            $db_tran->{found_in_blockchain} = 1;
            if ($db_tran->{type} ne 'withdrawal') {
                push @{$db_tran->{comments}}, 'Expected withdrawal, found ' . $db_tran->{type};
            }
            if (
                financialrounding(
                    price => $currency,
                    $blockchain_tran->{amount}
                ) != -$db_tran->{amount})
            {
                push @{$db_tran->{comments}}, 'Amount does not match - blockchain ' . $blockchain_tran->{amount} . ', db ' . $db_tran->{amount};
            }
        }
    }

    # Find out what's left over in the database
    for my $db_tran (grep { !$_->{found_in_blockchain} } values %db_by_address) {
        push @{$db_tran->{comments}}, 'Database entry not found in blockchain'
            unless grep { $db_tran->{status} eq $_ } qw(NEW REJECTED LOCKED);
    }

    my @hdr = (
        'Client ID',     'Type',                $currency . ' Address', 'Amount',
        'Status',        'DB Transaction date', 'Confirmations',        'Blockchain transaction ID',
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
    for my $db_tran (sort_by { $_->{address} } values %db_by_address) {
        print '<tr>';
        print '<td>' . encode_entities($_) . '</td>' for map { $_ // '' } @{$db_tran}{qw(client_loginid type address amount status date)};
        print '<td><span style="color: ' . ($_ >= 3 ? 'green' : 'gray') . '">' . encode_entities($_) . '</td>'
            for map { $_ // '' } @{$db_tran}{qw(confirmations)};
        print '<td><a target="_blank" href="' . ($blockchain_uri . $_) . '">' . encode_entities(substr $_, 0, 6) . '</td>'
            for @{$db_tran}{qw(transaction_id)};
        print '<td>' . encode_entities($db_tran->{payment_id}) . '</td>';
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
                $_ = '<a target="_blank" href="' . $blockchain_uri . $_ . '">' . $_ . '</a>' for $fields[1];
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
        die 'Invalid BTC command: ' . $cmd;
    }
} elsif ($view_action eq $va_cmds{new_deposit_address}) {
    my $rslt = $rpc_client->getnewaddress('manual');
    print '<p>New BTC address for deposits: <strong>' . encode_entities($rslt) . '</strong></p>';
}
code_exit_BO();
