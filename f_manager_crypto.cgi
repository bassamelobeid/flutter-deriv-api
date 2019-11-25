#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
no indirect;

use Date::Utility;
use Format::Util::Numbers qw/financialrounding formatnumber/;
use JSON::MaybeXS;
use HTML::Entities;
use List::UtilsBy qw(rev_nsort_by sort_by);
use POSIX ();
use ExchangeRates::CurrencyConverter qw(in_usd);
use YAML::XS;
use Math::BigFloat;
use Math::BigInt;
use Try::Tiny;

use Bitcoin::RPC::Client;
use Ethereum::RPC::Client;
use BOM::CTC::Currency;
use BOM::Config;

use BOM::User::Client;

use BOM::Backoffice::Auth0;
use BOM::Backoffice::PlackHelpers qw/PrintContentType_excel PrintContentType/;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Script::ValidateStaffPaymentLimit;
use BOM::CTC::Utility;
use BOM::Database::ClientDB;
use BOM::DualControl;
use LandingCompany::Registry;
use f_brokerincludeall;

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('CRYPTO CASHIER MANAGEMENT');

my $broker = request()->broker_code;
my $staff  = BOM::Backoffice::Auth0::get_staffname();
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

my $currency_url = BOM::Config::crypto()->{$currency}{blockchain_url};
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
            testnet     => BOM::Config::on_qa() ? 1 : 0
        }) || die $tt->error();
}

## CTC
Bar("Actions");

my $start_date = request()->param('start_date');
my $end_date   = request()->param('end_date');

try {
    if ($start_date && $start_date =~ /[0-9]{4}-[0-1][0-9]{1,2}-[0-3][0-9]{1,2}$/) {
        $start_date = Date::Utility->new("$start_date 00:00:00");
    } else {
        $start_date = Date::Utility->today()->truncate_to_month();
    }

    if ($end_date && $end_date =~ /[0-9]{4}-[0-1][0-9]{1,2}-[0-3][0-9]{1,2}$/) {
        $end_date = Date::Utility->new("$end_date 23:59:59");
    } else {
        $end_date = Date::Utility->today();
    }
}
catch {
    code_exit_BO('Invalid dates, please check the dates and try again');
};

if ($end_date->is_before($start_date)) {
    code_exit_BO("Invalid dates, the end date must be after the initial date");
}

my $clientdb = BOM::Database::ClientDB->new({broker_code => $broker});
my $dbic = $clientdb->db->dbic;

my $currency_wrapper = BOM::CTC::Currency->new(
    currency_code => $currency,
    broker_code   => $broker
);

my $exchange_rate = eval { in_usd(1.0, $currency) } // 'N.A.';

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
            testnet         => BOM::Config::on_qa() ? 1 : 0,
            staff           => $staff,
        }) || die $tt->error();
};

my @crypto_currencies =
    map { my $def = LandingCompany::Registry::get_currency_definition($_); $def->{type} eq 'crypto' ? {currency => $_, name => $def->{name}} : () }
    LandingCompany::Registry::all_currencies();
my $tt2 = BOM::Backoffice::Request::template;
$tt2->process(
    'backoffice/crypto_cashier/crypto_control_panel.html.tt',
    {
        exchange_rate  => $exchange_rate,
        controller_url => request()->url_for('backoffice/f_manager_crypto.cgi'),
        currency       => $currency,
        all_crypto     => [@crypto_currencies],
        cmd            => request()->param('command') // '',
        broker         => $broker,
        start_date     => $start_date->date_yyyymmdd,
        end_date       => $end_date->date_yyyymmdd,
        staff          => $staff,
    }) || die $tt2->error();

# Exchange rate should be populated according to supported cryptocurrencies.
if ($exchange_rate eq 'N.A.') {
    print "<p style='color:red'><strong>ERROR: No exchange rate found for currency " . $currency . ". Please contact IT. </strong></p>";
    code_exit_BO();
}

try {
    $currency_wrapper->get_info();
}
catch {
    warn "Failed to load $currency currency info: $_";
    print "<p style='color:red'><strong>ERROR: Failed to load $currency currency info. Please contact IT. </strong></p>";
    code_exit_BO();
};

if ($view_action eq 'withdrawals') {
    Bar("LIST OF TRANSACTIONS - WITHDRAWAL");

    code_exit_BO("Invalid address.")
        if $address and $address !~ /^[a-zA-Z0-9:?]+$/;
    code_exit_BO("Invalid action.")
        if $action and $action !~ /^[a-zA-Z]{4,15}$/;
    code_exit_BO("Invalid selection to view type of transactions.")
        if not $view_type or $view_type !~ /^(?:pending|verified|rejected|processing|performing_blockchain_txn|sent|error)$/;

    if ($action and $action =~ /^(?:Save|Verify|Reject)$/) {
        my $amount     = request()->param('amount');
        my $loginid    = request()->param('loginid');
        my $set_remark = request()->param('set_remark');

        # Error for rejection with no reason
        code_exit_BO("Please enter a remark explaining reason for rejection") if ($action eq 'Reject' && $set_remark eq '');

        # Check payment limit
        my $over_limit = BOM::Backoffice::Script::ValidateStaffPaymentLimit::validate($staff, in_usd($amount, $currency));
        code_exit_BO($over_limit->get_mesg()) if $over_limit;

        my $error;
        ($error) = $dbic->run(ping => sub { $_->selectrow_array('SELECT payment.ctc_set_remark(?, ?, ?)', undef, $address, $currency, $set_remark) })
            if $action eq 'Save';
        ($error) = $dbic->run(
            ping => sub {
                $_->selectrow_array('SELECT payment.ctc_set_withdrawal_verified(?, ?, ?, ?)',
                    undef, $address, $currency, $staff, ($set_remark ne '' ? $set_remark : undef));
            }) if $action eq 'Verify';
        ($error) = $dbic->run(
            ping => sub { $_->selectrow_array('SELECT payment.ctc_set_withdrawal_rejected(?, ?, ?)', undef, $address, $currency, $set_remark) })
            if $action eq 'Reject';

        code_exit_BO("ERROR: $error. Please check with someone from IT team before proceeding.")
            if ($error);
    }

    my $ctc_status = $view_type eq 'pending' ? 'LOCKED' : uc($view_type);
    # Fetch transactions according to filter option
    my $trxns = $dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                "SELECT * FROM payment.ctc_bo_get_withdrawal(NULL, NULL, ?, ?::payment.CTC_STATUS, NULL, NULL)",
                {Slice => {}},
                $currency, $ctc_status
            );
        });
    $display_transactions->($trxns);
} elsif ($view_action eq 'deposits') {
    Bar("LIST OF TRANSACTIONS - DEPOSITS");
    $view_type ||= 'new';
    code_exit_BO("Invalid selection to view type of transactions.") if $view_type !~ /^(?:new|pending|confirmed|error)$/;

    # Fetch all deposit transactions matching specified currency and status
    my $trxns = $dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                "SELECT * FROM payment.ctc_bo_get_deposit(NULL, NULL, ?, ?::payment.CTC_STATUS, NULL, NULL)",
                {Slice => {}},
                $currency, uc $view_type
            );
        });
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
        @{
            $dbic->run(
                fixup => sub {
                    $_->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(NULL, ?, ?)", {Slice => {}}, $search_query, $currency);
                })
        },
        @{
            $dbic->run(
                fixup => sub {
                    $_->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_deposit(NULL, ?, ?)", {Slice => {}}, $search_query, $currency);
                })
        },
    ) if ($search_type eq 'address');

    @trxns = (
        @{
            $dbic->run(
                fixup => sub {
                    $_->selectall_arrayref('SELECT * FROM payment.ctc_bo_get_withdrawal(?, NULL, ?)', {Slice => {}}, $search_query, $currency);
                })
        },
        @{
            $dbic->run(
                fixup => sub {
                    $_->selectall_arrayref('SELECT * FROM payment.ctc_bo_get_deposit(?, NULL, ?)', {Slice => {}}, $search_query, $currency);
                })
        },
    ) if ($search_type eq 'loginid');

    $display_transactions->(\@trxns);

} elsif ($view_action eq 'reconcil') {
    Bar($currency . ' Reconciliation');

    if (Date::Utility::days_between($end_date, $start_date) > 30) {
        print "<p style='color:red'><strong>ERROR: Cannot accept dates more than 30 days apart. Please edit start and end dates. </strong></p>";
        code_exit_BO();
    }

    my @recon_list = $currency_wrapper->recon_report($start_date, $end_date);

    unless (scalar @recon_list) {
        code_exit_BO("Empty reconciliation report. There is no record to display.");
    }

    my @hdr = (
        'Client ID',        'Type',   'Address',     'Amount',       'Amount USD',      'Fee',
        'Protocol Cost',    'Status', 'Status date', 'Payment date', 'Blockchain date', 'Confirmations',
        'Transaction Hash', 'Errors'
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

    TRAN:
    for my $db_tran (@recon_list) {
        next TRAN if $db_tran->is_status_in(qw(NEW MIGRATED)) and not $show_new_addresses;
        print '<tr>';
        print '<td>' . encode_entities($_) . '</td>' for map { $_ && $_ ne '' ? $_ : '' } @{$db_tran}{qw(account transaction_type)};

        my $address = $db_tran->{to} || $db_tran->{from};
        my $encoded_address = encode_entities($address);
        print '<td><a href="' . $address_uri . $encoded_address . '" target="_blank">' . $encoded_address . '</a></td>';

        my $amount = formatnumber('amount', $currency, financialrounding('price', $currency, $db_tran->{amount}));
        my $usd_amount = formatnumber('amount', 'USD', financialrounding('price', 'USD', in_usd($db_tran->{amount}, $currency)));
        # for recon only, we can't consider fee as a 8 decimal places value
        # for ethereum the fees values has more than that, and since we can't
        # get any difference in the recon report, better show the correct value
        # for amount we have a limit for each coin, so we don't need to show the entire value like in the fee
        my $fee           = Math::BigFloat->new($db_tran->{fee})->bstr;
        my $protocol_cost = Math::BigFloat->new($db_tran->{protocol_cost})->bstr;

        print '<td style="text-align:right;">' . encode_entities($_) . '</td>' for ($amount, '$' . $usd_amount, $fee, $protocol_cost);
        print '<td>' . encode_entities($_) . '</td>' for map { $_ // '' } @{$db_tran}{qw(status)};
        print '<td sorttable_customkey="' . (sprintf "%012d", $_ ? Date::Utility->new($_)->epoch : 0) . '">' . encode_entities($_) . '</td>'
            for map { $_ // '' } @{$db_tran}{qw(status_date database_date blockchain_date)};
        print '<td><span style="color: ' . ($_ + 0 >= 3 ? 'green' : 'gray') . '">' . encode_entities($_) . '</td>'
            for map { $_ // 0 } @{$db_tran}{qw(confirmations)};
        print '<td>';
        if ($db_tran->{transaction_hash}) {
            print '<a target="_blank" href="'
                . ($transaction_uri . $db_tran->{transaction_hash}) . '">'
                . encode_entities($db_tran->{transaction_hash})
                . '</a><br>';
        }

        print '</td>';
        print '<td style="color:red;">' . (join '<br><br>', map { encode_entities($_) } @{$db_tran->{comments} || []}) . '</td>';
        print '</tr>';
    }

    print '</tbody></table>';
} elsif ($view_action eq 'run') {
    my $cmd = request()->param('command');

    if ($cmd eq 'getbalance') {
        my $get_balance = $currency_wrapper->get_total_balance();
        for my $currency_balance (keys %$get_balance) {
            print sprintf("<p>%s:<pre>%s</pre></p>", $currency_balance, formatnumber('amount', $currency_balance, $get_balance->{$currency_balance}));
        }
    } elsif ($cmd eq 'getinfo') {
        my $get_info = $currency_wrapper->get_info;
        for my $info (keys %$get_info) {
            next if ref($get_info->{$info}) =~ /HASH|ARRAY/;
            print sprintf("<p><b>%s:</b><pre>%s</pre></p>", $info, $get_info->{$info});
        }
    } else {
        die 'Invalid ' . $currency . ' command: ' . $cmd;
    }
} elsif ($view_action eq 'new_deposit_address') {
    my $new_address = $currency_wrapper->get_new_bo_address();
    print '<p>' . $currency . ' address for deposits: <strong>' . encode_entities($new_address) . '</strong></p>' if $new_address;
    print
        '<p style="color:red"><strong>WARNING! An address has not been found. Please contact Devops to obtain a new address to update this in the configuration.</strong></p>'
        unless $new_address;
} elsif ($view_action eq 'prioritize_confirmation') {
    my $prioritize_address = request()->param('prioritize_address');
    if ($prioritize_address) {
        my $clientdb = BOM::Database::ClientDB->new({broker_code => 'CR'});
        my $dbic = $clientdb->db->dbic;

        $prioritize_address =~ s/^\s+|\s+$//g;
        if ($currency_wrapper->is_valid_address($prioritize_address)) {
            my $status = $currency_wrapper->prioritize_address($prioritize_address);

            if ($status) {
                print "<p style='color:green'><strong>SUCCESS: Requested priority</strong></p>";
            } else {
                print "<p style='color:red'><strong>ERROR: can't prioritize address</strong></p>";
            }
        } else {
            print "<p style='color:red'><strong>ERROR: invalid address format</strong></p>";
        }
    } else {
        print "<p style=\"color:red\"><strong>ERROR: Address not found</strong></p>";
    }
}
code_exit_BO();
