#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
no indirect;

use Date::Utility;
use Format::Util::Numbers qw/financialrounding formatnumber/;
use JSON::MaybeXS;
use HTML::Entities;
use List::UtilsBy qw(rev_nsort_by sort_by extract_by);
use POSIX ();
use ExchangeRates::CurrencyConverter qw(in_usd);
use YAML::XS;
use Math::BigFloat;
use Math::BigInt;
use Syntax::Keyword::Try;

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
use BOM::CTC::Database;
use BOM::DualControl;
use LandingCompany::Registry;
use f_brokerincludeall;
use BOM::Cryptocurrency::Helper qw(get_crypto_withdrawal_pending_total reprocess_address);
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Context;
use BOM::Platform::Context::Request;
use Brands;
use constant REJECTION_REASONS => {
    low_trade => {
        reason => 'less trade/no trade',
        remark => 'Low trade, ask client for justification and to request a new payout'
    },
    back_to_fiat => {
        reason => 'back to fiat account',
        remark => 'Deposit was done via fiat, the client needs to withdraw via fiat account'
    },
    crypto_low_trade => {
        reason => 'insufficient trade (manual refund to card)',
        remark => 'Low Trade, need to manual refund back to the card, the client needs to confirm the refund'
    },
    authentication_needed => {
        reason => 'authentication needed',
        remark => 'Authentication needed'
    },
    less_trade_back_to_fiat_account => {
        reason => 'less trade, back to fiat account',
        remark => 'Deposit was done via fiat, traded less hence needs to withdraw via fiat'
    },
    default => {
        reason => 'contact CS',
        remark => 'contact CS'
    }};

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('CRYPTO CASHIER MANAGEMENT');

sub notify_crypto_withdrawal_rejected {
    my ($loginid, $reason, $app_id) = @_;
    $reason //= "unknown";

    my $client = BOM::User::Client->new({loginid => $loginid});

    my $brand = defined $app_id ? Brands->new_from_app_id($app_id) : request->brand;
    my $req   = BOM::Platform::Context::Request->new(brand_name => $brand->name);
    BOM::Platform::Context::request($req);

    my $email_subject = localize('Your withdrawal request has been declined');
    my $email_data    = {
        name           => $client->first_name,
        title          => localize("We were unable to process your withdrawal"),
        reason         => $reason,
        client_loginid => $client->loginid,
        brand_name     => ucfirst $brand->name,
    };
    send_email({
        to                    => $client->email,
        subject               => $email_subject,
        template_name         => 'withdrawal_reject',
        template_args         => $email_data,
        template_loginid      => $client->loginid,
        email_content_is_html => 1,
        use_email_template    => 1,
        use_event             => 1,
    });
}

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
my $show_new_addresses = request()->param('include_new') // '';
my $fee_recon          = request()->param('fee_recon');
# view type is a filter option which is used to sort transactions
# based on their status:it might be either pending, verified, rejected,
# processing,performing_blockchain_txn, sent or error.
# Accessable on Withdrawal action only. By defaullt Withdrawal page
# shows `pending` transactions.
my $view_type = request()->param('view_type') // 'pending';
# Currently, the controller renders page according to Deposit,
# Withdrawal and Search actions.
my $view_action = request()->param('view_action') // '';
# if show_all_pendings is true, all pending withdrawal transaction will be listed;
#otherwise, those verified/rejected by the current user will be filtered out.
my $show_all_pendings = request()->param('show_all_pendings');
# show only one step authorised
my $show_one_authorised = request()->param('show_one_authorised');

code_exit_BO("Invalid currency.")
    if $currency !~ /^[a-zA-Z0-9]{2,20}$/;

my $currency_wrapper = BOM::CTC::Currency->new(currency_code => $currency);

my $dbic = BOM::CTC::Database->new()->cryptodb_dbic();

my $main_address           = $currency_wrapper->account_config->{account}->{address};
my $blockchain_address     = $currency_wrapper->get_address_blockchain_url();
my $blockchain_transaction = $currency_wrapper->get_transaction_blockchain_url();
code_exit_BO('No currency urls for ' . $currency) unless $blockchain_transaction and $blockchain_address;

my $exchange_rate         = eval { in_usd(1.0, $currency) } // 'N.A.';
my $sweep_limit_max       = $currency_wrapper->config->{sweep}{max_transfer};
my $sweep_limit_min       = $currency_wrapper->config->{sweep}{min_transfer};
my $sweep_reserve_balance = $currency_wrapper->sweep_reserve_balance();

my $transaction_uri = URI->new($blockchain_transaction);
my $address_uri     = URI->new($blockchain_address);
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

Bar("$currency Info");
$tt->process(
    'backoffice/crypto_cashier/crypto_info.html.tt',
    {
        exchange_rate         => $exchange_rate,
        currency              => $currency,
        main_address          => $main_address,
        sweep_limit_max       => $sweep_limit_max,
        sweep_limit_min       => $sweep_limit_min,
        sweep_reserve_balance => $sweep_reserve_balance,
    }) || die $tt->error();

## CTC
Bar("$currency Actions");

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
} catch {
    code_exit_BO('Invalid dates, please check the dates and try again');
}

if ($end_date->is_before($start_date)) {
    code_exit_BO("Invalid dates, the end date must be after the initial date");
}

my $display_transactions = sub {
    my $trxns = shift;
    # Assign USD equivalent value
    for my $trx (@$trxns) {
        $trx->{amount} //= 0;    # it will be undef on newly generated addresses
        $trx->{usd_amount} = formatnumber('amount', 'USD', $trx->{amount} * $exchange_rate);

        $trx->{statement_link} = request()->url_for(
            'backoffice/f_manager_history.cgi',
            {
                broker  => $broker,
                loginID => $trx->{client_loginid},
            });

        $trx->{profit_link} = request()->url_for(
            'backoffice/f_profit_check.cgi',
            {
                broker    => $broker,
                loginID   => $trx->{client_loginid},
                startdate => Date::Utility->today()->_minus_months(1)->date,
                enddate   => Date::Utility->today()->date,
            });

        # We should prevent verifying the withdrawal transaction by the payment team
        # if the client withdrawal is locked
        my $client = BOM::User::Client->new({loginid => $trx->{client_loginid}});
        $trx->{is_withdrawal_locked} =
            ($client->status->withdrawal_locked || $client->status->cashier_locked || $client->status->no_withdrawal_or_trading)
            if $trx->{transaction_type} eq 'withdrawal';

        $trx->{client_status} =
              $client->fully_authenticated      ? 'Fully Authenticated'
            : $client->status->age_verification ? 'Age Verified'
            :                                     'Unauthenticated';
    }

    #sort rejection reasons & grep only required data for template
    my @rejection_reasons_tpl =
        map  { {index => $_, reason => REJECTION_REASONS->{$_}->{reason}} }
        sort { REJECTION_REASONS->{$a}->{reason} cmp REJECTION_REASONS->{$b}->{reason} }
        keys REJECTION_REASONS->%*;

    # Render template page with transactions
    my $tt = BOM::Backoffice::Request::template;
    $tt->process(
        'backoffice/crypto_cashier/manage_crypto_transactions.tt',
        {
            transactions        => $trxns,
            broker              => $broker,
            currency            => $currency,
            transaction_uri     => $transaction_uri,
            address_uri         => $address_uri,
            view_action         => $view_action,
            view_type           => $view_type,
            controller_url      => request()->url_for('backoffice/f_manager_crypto.cgi'),
            testnet             => BOM::Config::on_qa() ? 1 : 0,
            staff               => $staff,
            show_all_pendings   => $show_all_pendings   // '',
            show_one_authorised => $show_one_authorised // '',
            fetch_url           => request()->url_for('backoffice/fetch_client_details.cgi'),
            rejection_reasons   => \@rejection_reasons_tpl,
        }) || die $tt->error();
};

my $pending_withdrawal_amount = request()->param('pending_withdrawal_amount');

my $pending_estimated_fee;
if ($view_action eq 'withdrawals') {
    my $withdrawal_sum = get_crypto_withdrawal_pending_total($currency);
    $pending_withdrawal_amount = $withdrawal_sum->{pending_withdrawal_amount};
    $pending_estimated_fee     = $withdrawal_sum->{pending_estimated_fee};
}

my @crypto_currencies =
    sort { $a->{currency} cmp $b->{currency} }
    map { {currency => $_, name => LandingCompany::Registry::get_currency_definition($_)->{name}} } LandingCompany::Registry::all_crypto_currencies();
my $tt2 = BOM::Backoffice::Request::template;
$tt2->process(
    'backoffice/crypto_cashier/crypto_control_panel.html.tt',
    {
        exchange_rate             => $exchange_rate,
        controller_url            => request()->url_for('backoffice/f_manager_crypto.cgi'),
        currency                  => $currency,
        all_crypto                => [@crypto_currencies],
        cmd                       => request()->param('command') // '',
        broker                    => $broker,
        start_date                => $start_date->date_yyyymmdd,
        end_date                  => $end_date->date_yyyymmdd,
        show_all_pendings         => $show_all_pendings,
        show_one_authorised       => $show_one_authorised,
        staff                     => $staff,
        pending_withdrawal_amount => $pending_withdrawal_amount,
        main_address              => $main_address,
        include_new               => $show_new_addresses,
    }) || die $tt2->error();

# Exchange rate should be populated according to supported cryptocurrencies.
if ($exchange_rate eq 'N.A.') {
    print "<p class='error'><strong>ERROR: No exchange rate found for currency " . $currency . ". Please contact IT. </strong></p>";
    code_exit_BO();
}

try {
    $currency_wrapper->get_info();
} catch {
    warn "Failed to load $currency currency info: $@";
    print "<p class='error'><strong>ERROR: Failed to load $currency currency info. Please contact IT. </strong></p>";
    code_exit_BO();
}

if ($view_action eq 'withdrawals') {
    my $main_address_balance = $currency_wrapper->get_main_address_balance();

    print "<hr><h3>Available Balance(s) for Payout:</h3>";
    for my $currency_of_balance (sort keys %$main_address_balance) {
        my $balance        = Math::BigFloat->new($main_address_balance->{$currency_of_balance});
        my $remaining_text = '';
        if ($currency_of_balance eq $currency) {
            my $remaining = $balance->copy->bsub($pending_withdrawal_amount);
            $remaining_text = sprintf(
                " (Remaining after <b>payout</b>: <b class='%s'>%s</b>)",
                $remaining->is_pos ? 'success' : 'error',
                formatnumber('amount', $currency_of_balance, $remaining->bstr),
            );
        } else {
            my $remaining = $balance->copy->bsub($pending_estimated_fee);
            $remaining_text = sprintf(
                " (Remaining after <b>total estimated fees</b>: <b class='%s'>%s</b>)",
                $remaining->is_pos ? 'success' : 'error',
                formatnumber('amount', $currency_of_balance, $remaining->bstr),
            );
        }
        print sprintf("<p>%s : <b>%s</b>$remaining_text</p>", $currency_of_balance, formatnumber('amount', $currency_of_balance, $balance->bstr));
    }
    print
        sprintf("<p>NOTE: The above values calculated on <b>%s</b>. To get new values, please click the <b>Withdrawal Transactions</b> button above.",
        Date::Utility->new()->datetime_yyyymmdd_hhmmss);

    Bar("LIST OF TRANSACTIONS - WITHDRAWAL");

    code_exit_BO("Invalid address.")
        if $address and $address !~ /^[a-zA-Z0-9:?]+$/;
    code_exit_BO("Invalid action.")
        if $action and $action !~ /^[a-zA-Z]{4,15}$/;
    code_exit_BO("Invalid selection to view type of transactions.")
        if not $view_type or $view_type !~ /^(?:pending|verified|rejected|cancelled|processing|performing_blockchain_txn|sent|error)$/;

    if (my ($is_bulk, $trx_action) = ($action || '') =~ /^(bulk|)(Save|Verify|Reject)$/) {
        my @params_list;
        if ($is_bulk) {
            my $selected_transactions = request->param('selected_transactions');
            code_exit_BO("ERROR: No withdrawal transaction is selected for <b>Bulk $trx_action</b>.") unless $selected_transactions;

            my $bulk_data;
            try {
                $bulk_data = decode_json($selected_transactions);
            } catch {
                code_exit_BO('ERROR: Invalid JSON format for bulk action on withdrawal transactions received. Please contact BE.');
            }
            @params_list = map { +{$bulk_data->{$_}->%*, trx_id => $_} } sort keys $bulk_data->%*;
        } else {
            my %params = request()->params->%*;
            @params_list = {%params{qw(trx_id amount remark rejection_reason loginid app_id)}};
        }

        my %trx_actions_map = (
            Save   => \&withdrawal_save_remark,
            Verify => \&withdrawal_verify,
            Reject => \&withdrawal_reject,
        );
        my @errors;
        for my $params (@params_list) {
            my $trx_error = $trx_actions_map{$trx_action}->(
                $params->%*,
                dbic     => $dbic,
                staff    => $staff,
                currency => $currency,
            );
            push @errors, $trx_error || ();
        }

        code_exit_BO(join '<br />', @errors) if @errors;
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

    if ($show_one_authorised) {
        #filter one step authorised txn
        @$trxns = extract_by {
            any { $_ } $_->{authorisers}->@*
        }
        @$trxns;
    }

    unless ($show_all_pendings or $view_type ne 'pending') {
        #filter pending transactions already audited by the current staff
        @$trxns = extract_by {
            not($_->{authorisers} and grep { /^$staff$/ } $_->{authorisers}->@*)
        }
        @$trxns;
    }

    $display_transactions->($trxns);

} elsif ($view_action eq 'auto_reject_insufficient') {
    my $trxns = $dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                "SELECT * FROM payment.ctc_bo_get_withdrawal(NULL, NULL, ?, ?::payment.CTC_STATUS, NULL, NULL)",
                {Slice => {}},
                $currency, 'LOCKED'
            );
        });

    my $count = 0;
    for my $trxn (@$trxns) {
        my $client         = BOM::User::Client->new({loginid => $trxn->{client_loginid}});
        my $client_balance = $client->default_account->balance;
        if ($client_balance < $trxn->{amount}) {
            my ($error) = $dbic->run(
                ping => sub {
                    $_->selectrow_array('SELECT payment.ctc_set_withdrawal_rejected(?, ?, ?)', undef, $trxn->{id}, 'Insufficient balance', $staff);
                });

            code_exit_BO(sprintf("ERROR: %s. Failed to auto-reject a withdrawal. %d were rejected so far.", $error, $count))
                if $error;

            $count++;
        }
    }
    print sprintf("<p><b>%d withdrawals rejected</b></p>", $count);

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
        print "<p class='error'><strong>ERROR: Cannot accept dates more than 30 days apart. Please edit start and end dates. </strong></p>";
        code_exit_BO();
    }

    my @recon_list;
    if ($fee_recon) {
        @recon_list = $currency_wrapper->recon_report_btc_fee($start_date, $end_date);
    } else {
        @recon_list = $currency_wrapper->recon_report($start_date, $end_date, $show_new_addresses);
    }

    unless (scalar @recon_list) {
        code_exit_BO("Empty reconciliation report. There is no record to display.");
    }

    my @hdr = (
        'Client ID',     'Type',   'Address',     'Amount',          'Amount USD',    'Fee',
        'Protocol Cost', 'Status', 'Status date', 'Blockchain date', 'Confirmations', 'Transaction Hash',
        'Errors'
    );
    my $filename = join '-', $start_date->date_yyyymmdd, $end_date->date_yyyymmdd, $currency;

    # TODO: move representation logic to template
    print <<"EOF";
<div class="row">
<a class="btn btn--primary" download="${filename}.xls" href="#" onclick="return ExcellentExport.excel(this, 'recon_table', '$filename');">Export to Excel</a>
<a class="btn btn--primary" download="${filename}.csv" href="#" onclick="return ExcellentExport.csv(this, 'recon_table');">Export to CSV</a>
</div>
EOF
    print '<div class="scrollable"><table id="recon_table" class="border nowrap sortable hover"><thead><tr>';
    print '<th scope="col">' . encode_entities($_) . '</th>' for @hdr;
    print '</thead><tbody>';

    TRAN:
    for my $db_tran (@recon_list) {
        print '<tr>';
        print '<td>' . encode_entities($_) . '</td>' for map { $_ && $_ ne '' ? $_ : '' } @{$db_tran}{qw(account transaction_type)};

        my $address         = $db_tran->{to} || $db_tran->{from};
        my $encoded_address = encode_entities($address);
        print '<td><a class="link" href="' . $address_uri . $encoded_address . '" target="_blank">' . $encoded_address . '</a></td>';
        my $amount     = $db_tran->{amount} // 0;
        my $currency   = $fee_recon ? $currency_wrapper->parent_currency : $currency;
        my $usd_amount = formatnumber('amount', 'USD', financialrounding('price', 'USD', in_usd($amount, $currency)));

        # for recon only, we can't consider fee as a 8 decimal places value
        # for ethereum the fees values has more than that, and since we can't
        # get any difference in the recon report, better show the correct value
        # for amount we have a limit for each coin, so we don't need to show the entire value like in the fee
        my $fee           = Math::BigFloat->new($db_tran->{fee})->bstr;
        my $protocol_cost = Math::BigFloat->new($db_tran->{protocol_cost})->bstr;

        print '<td class="right">' . encode_entities($_) . '</td>' for ($amount, '$' . $usd_amount, $fee, $protocol_cost);
        print '<td>' . encode_entities($_) . '</td>'               for map { $_ // '' } @{$db_tran}{qw(status)};
        print '<td sorttable_customkey="' . (sprintf "%012d", $_ ? Date::Utility->new($_)->epoch : 0) . '">' . encode_entities($_) . '</td>'
            for map { $_ // '' } @{$db_tran}{qw(status_date blockchain_date)};
        print '<td><span class="' . ($_ + 0 >= 3 ? 'success' : 'text-muted') . '">' . encode_entities($_) . '</td>'
            for map { $_ // 0 } @{$db_tran}{qw(confirmations)};
        print '<td>';
        if ($db_tran->{transaction_hash}) {
            print '<a class="link" target="_blank" href="'
                . ($transaction_uri . $db_tran->{transaction_hash}) . '">'
                . encode_entities($db_tran->{transaction_hash})
                . '</a><br>';
        }

        print '</td>';
        print '<td class="error">' . (join '<br><br>', map { encode_entities($_) } @{$db_tran->{comments} || []}) . '</td>';
        print '</tr>';
    }

    print '</tbody></table></div>';
} elsif ($view_action eq 'run') {
    my $cmd = request()->param('command');

    if ($cmd eq 'getbalance') {
        my $get_balance = $currency_wrapper->get_main_address_balance();
        print "<b>Available Balance(s) for payout: </b>";
        for my $currency_balance (sort keys %$get_balance) {
            print sprintf("<p>%s : <b>%s</b></p>", $currency_balance, $get_balance->{$currency_balance});
        }
        #  We won't calculate for ETH and ERC20 as it will cost performance.
    } elsif ($cmd eq 'getwallet') {
        my $get_balance = $currency_wrapper->get_wallet_balance();
        print "<b>Total Balance(s) in Wallet: </b>";
        for my $currency_balance (sort keys %$get_balance) {
            print sprintf("<p>%s : <b>%s</b></p>", $currency_balance, $get_balance->{$currency_balance});
        }
    } elsif ($cmd eq 'getinfo') {
        my $get_info = $currency_wrapper->get_info;
        for my $info (sort keys %$get_info) {
            next if ref($get_info->{$info}) =~ /HASH|ARRAY/;
            print sprintf("<p><b>%s:</b><pre>%s</pre></p>", $info, $get_info->{$info});
        }
    } else {
        die 'Invalid ' . $currency . ' command: ' . $cmd;
    }
} elsif ($view_action eq 'reprocess_confirmation') {
    my $address_to_reprocess = request()->param('address_to_reprocess');
    print reprocess_address($currency_wrapper, $address_to_reprocess);
}

code_exit_BO();

=head2 withdrawal_save_remark

Sets the remark for a withdrawal transaction.

Takes the following named arguments:

=over 4

=item * C<trx_id> - Transaction ID

=item * C<remark> - The remark text to be set

=back

Returns error if there is any.

=cut

sub withdrawal_save_remark {
    my %args = @_;

    my ($trx_id, $remark, $dbic) = @args{qw(trx_id remark dbic)};

    my $error = $dbic->run(
        ping => sub {
            $_->selectrow_array('SELECT payment.ctc_set_remark(?, ?)', undef, $trx_id, $remark);
        });

    return $error;
}

=head2 withdrawal_verify

Verifies a withdrawal transaction and sets a remark if provided.

Takes the following named arguments:

=over 4

=item * C<trx_id> - Transaction ID

=item * C<amount> - Amount of the transaction

=item * C<remark> - (optional) The remark text to be set

=item * C<loginid> - Client's loginid

=item * C<staff> - The staff name

=back

Returns error if there is any.

=cut

sub withdrawal_verify {
    my %args = @_;

    my ($trx_id, $amount, $remark, $loginid, $staff, $dbic, $currency) = @args{qw(trx_id amount remark loginid staff dbic currency)};
    my $client = BOM::User::Client->new({loginid => $loginid});

    return "Error in verifying transaction id: $trx_id. The client $loginid withdrawal is locked."
        if $client->status->withdrawal_locked;

    my $over_limit = BOM::Backoffice::Script::ValidateStaffPaymentLimit::validate($staff, in_usd($amount, $currency));
    return "Error in verifying transaction id: $trx_id. " . $over_limit->get_mesg()
        if $over_limit;

    my $approvals_required = BOM::Config::Runtime->instance->app_config->payments->crypto_withdrawal_approvals_required;
    my @client_siblings    = map { $_->loginid } $client->siblings->@*;
    my $error              = $dbic->run(
        ping => sub {
            $_->selectrow_array(
                'SELECT payment.ctc_set_withdrawal_verified(?, ?::JSONB, ?, ?, ?)',
                undef, $trx_id, $approvals_required, $staff, ($remark || undef),
                \@client_siblings,
            );
        });

    return $error;
}

=head2 withdrawal_reject

Rejects a withdrawal transaction and sets the remark accordingly.

Takes the following named arguments:

=over 4

=item * C<trx_id> - Transaction ID

=item * C<remark> - (optional) The remark text to be set

=item * C<rejection_reason> - The reason for rejecting the withdrawal

=item * C<loginid> - Client's loginid

=item * C<staff> - The staff name

=back

Returns error if there is any.

=cut

sub withdrawal_reject {
    my %args = @_;

    my ($trx_id, $remark, $rejection_reason, $loginid, $staff, $dbic, $app_id) = @args{qw(trx_id remark rejection_reason loginid staff dbic  app_id)};

    code_exit_BO('Please select a reason for rejection to notify client')
        unless $rejection_reason;

    code_exit_BO('Unexpected rejection reason')
        unless defined REJECTION_REASONS->{$rejection_reason};

    $remark .= "[@{[ REJECTION_REASONS->{$rejection_reason}->{remark} ]}]";

    my $error = $dbic->run(
        ping => sub {
            $_->selectrow_array('SELECT payment.ctc_set_withdrawal_rejected(?, ?, ?)', undef, $trx_id, $remark, $staff);
        });

    notify_crypto_withdrawal_rejected($loginid, $rejection_reason, $app_id)
        unless $error;

    return $error;
}
