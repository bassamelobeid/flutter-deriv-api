#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Path::Tiny;
use Syntax::Keyword::Try;
use Date::Utility;
use HTML::Entities;
use Format::Util::Numbers qw/formatnumber/;
use Scalar::Util          qw(looks_like_number);
use JSON::MaybeXS;

use LandingCompany::Registry;

use f_brokerincludeall;
use BOM::Database::DataMapper::Payment;
use BOM::Database::ClientDB;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Utility;
use BOM::Platform::Event::Emitter;
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::DualControl;
use BOM::User::AuditLog;
use BOM::Backoffice::Config;
use BOM::Backoffice::Sysinit ();
use BOM::Config::Runtime;
use BOM::Rules::Engine;
use ExchangeRates::CurrencyConverter qw(in_usd);

use Log::Any qw($log);
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('Batch Credit/Debit to Clients Accounts');

if (BOM::Config::Runtime->instance->app_config->system->suspend->payments) {
    code_exit_BO('ERROR: Payments are suspended.');
}

my $cgi               = CGI->new;
my $broker            = request()->broker_code;
my $clerk             = BOM::Backoffice::Auth::get_staffname();
my $confirm           = $cgi->param('confirm');
my $preview           = $cgi->param('preview');
my $payments_csv_file = $cgi->param('payments_csv_file') || sprintf '/tmp/batch_payments_%d.csv', rand(1_000_000);
my $skip_validation   = $cgi->param('skip_validation')   || 0;
my $notify_client     = $cgi->param('notify_client')     || 0;
my $format            = $confirm                         || $preview || die "either preview or confirm";
my $now               = Date::Utility->new;
my $payments_csv      = $cgi->param('payments_csv');
my $payment_limits    = JSON::MaybeXS->new->decode(BOM::Config::Runtime->instance->app_config->payments->payment_limits);

my $staff_limit = $payment_limits->{$clerk} or code_exit_BO("ERROR: There is no payment limit configured for user $clerk");

Bar('Batch Credit/Debit to Clients Accounts');

if ($preview) {
    if ($payments_csv !~ /csv$/) {
        print "<h3 class=\"error\">ERROR: The provided file \"", encode_entities($payments_csv),
            "\" is not a CSV file.</h3><p>Please save it as <b>CSV (comma-separated values) file</b> in Excel first.</p>";
        code_exit_BO();
    }
    my $payments_csv_fh = $cgi->upload('payments_csv');
    binmode $payments_csv_fh, ':encoding(UTF-8)';
    open my $fh, '>:encoding(UTF-8)', $payments_csv_file or die "writing upload: $!";
    while (my $line = <$payments_csv_fh>) {
        $line =~ s/\s*$//;    # remove various combos of unix/windows rec-separators
        $fh->print("$line\n");
    }
    close $fh;
}

my @payment_lines = Path::Tiny::path($payments_csv_file)->lines_utf8;

my ($transtype, $control_code);
if ($confirm) {
    unlink $payments_csv_file;

    $control_code = $cgi->param('DCcode');
    $transtype    = $cgi->param('transtype');

    my $error = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $transtype
        })->validate_batch_payment_control_code($control_code, \@payment_lines);
    if ($error) {
        print encode_entities($error->get_mesg());
        code_exit_BO();
    }
}

my @hdgs = (
    'Line Number', 'Login Id', 'Name', 'Debit/credit/reversal', 'Payment Type', 'Trace ID',
    'Payment Processor',
    'Payment Method',
    'Currency', 'Amount', 'Comment', 'Transaction ID', 'Notes'
);

my $client_account_table = '<h3>Batch details</h3><table class="border full-width">' . '<tr>' . join('', map { "<th>$_</th>" } @hdgs) . '</tr>';

my %summary_amount_by_currency;
my @invalid_lines;
my $line_number;
my %client_to_be_processed;
my $error;

read_csv_row_and_callback(
    \@payment_lines,
    sub {
        my $cols_found = @_;
        my (
            $login_id, $action, $payment_type,      $payment_processor, $payment_method, $trace_id,
            $currency, $amount, $statement_comment, $transaction_id,    $cols_expected,  $transaction_type
        );
        if ($format eq 'doughflow') {
            ($login_id, $action, $trace_id, $payment_processor, $payment_method, $currency, $amount, $transaction_id) = @_;
            $payment_type = 'external_cashier';
            if (($action // '') eq 'credit') {
                $cols_expected = 8;
            } else {
                $cols_expected = 7;
            }
        } else {
            ($login_id, $action, $payment_type, $currency, $amount, $statement_comment) = @_;
            $cols_expected = 6;
        }

        $line_number++;

        my $client;

        try {
            my $curr_regex = LandingCompany::Registry::get_currency_type($currency) eq 'fiat' ? '^\d*\.?\d{1,2}$' : '^\d*\.?\d{1,8}$';
            $amount = formatnumber('price', $currency, $amount) if looks_like_number($amount);

            die "Found $cols_found fields, needed $cols_expected for $format payments\n" unless $cols_found == $cols_expected;
            die "Invalid transaction type: $action\n"                   if $action !~ /^(debit|credit|reversal)$/;
            die "Invalid $amount: $amount\n"                            if $amount !~ $curr_regex or $amount == 0;
            die "'Statement comment can not be empty for this format\n" if $format ne 'doughflow' && !$statement_comment;

            $client = BOM::User::Client->new({loginid => $login_id}) or die "Invalid loginid: $login_id\n";
            die "Currency $currency does not match client $login_id currency of " . $client->account->currency_code . "\n"
                if $client->account->currency_code ne $currency;
            die "Amount $currency $amount exceeds the payment limit of USD $staff_limit for user $clerk\n"
                if in_usd($amount, $currency) > $staff_limit;

            my $signed_amount = $action eq 'debit' ? $amount * -1 : $amount;

            if ($format eq 'doughflow') {
                if ($action eq 'credit') {
                    die "Transaction id is mandatory for doughflow credit\n" if ($transaction_id // '') !~ '\w+';
                    die "Payment processor is mandatory for doughflow credit\n" unless $payment_processor;
                    $transaction_type = 'deposit';
                } else {
                    die "Payment method is mandatory for doughflow debit and reversal\n" unless $payment_method;
                    $transaction_type = 'withdrawal'          if $action eq 'debit';
                    $transaction_type = 'withdrawal_reversal' if $action eq 'reversal';
                }
                $statement_comment =
                    _doughflow_tx_statement_comment($transaction_type, $trace_id, $payment_method, $payment_processor, $transaction_id);

            }
            unless ($skip_validation) {
                $client->validate_payment(
                    currency    => $currency,
                    amount      => $signed_amount,
                    rule_engine => BOM::Rules::Engine->new(client => $client));
            }
            if ($payment_type ne 'test_account') {
                # check pontential duplicate entry
                my $payment_mapper = BOM::Database::DataMapper::Payment->new({
                    client_loginid => $login_id,
                    currency_code  => $currency,
                });

                chomp($statement_comment);
                if (
                    my $duplicate_record = $payment_mapper->get_transaction_id_of_account_by_comment({
                            amount  => ($action eq 'debit' ? $amount * -1 : $amount),
                            comment => $statement_comment
                        }))
                {
                    die "Same transaction found in client account. Check [transaction id: $duplicate_record]\n";
                }

            }

        } catch ($e) {
            $error = ref $e eq 'HASH' ? $e->{message_to_client} : $e;
        }

        my %row = (
            line_number       => $line_number,
            login_id          => $login_id,
            name              => ($client ? $client->full_name : 'n/a'),
            action            => $action,
            payment_type      => $payment_type,
            currency          => $currency,
            amount            => $amount,
            comment           => $statement_comment,
            payment_processor => $payment_processor,
            payment_method    => $payment_method,
            trace_id          => $trace_id,
            transaction_id    => $transaction_id,
        );

        if ($error) {
            $client_account_table .= construct_row_line(%row, error => $error);
            push @invalid_lines, qq[<a class="link" href="#ln$line_number">Invalid line $line_number</a> : ] . encode_entities($error);
            return;
        }

        if (not $preview and $confirm and @invalid_lines == 0) {

            my $signed_amount = $amount;
            $signed_amount *= -1 if $action eq 'debit';
            my $err;
            my $trx;
            try {
                if ($payment_type eq 'mt5_adjustment') {
                    $trx = $client->payment_mt5_transfer(
                        currency     => $currency,
                        amount       => $signed_amount,
                        payment_type => 'mt5_transfer',
                        remark       => $statement_comment,
                        staff        => $clerk,
                    );
                } else {
                    my $rule_engine = BOM::Rules::Engine->new(client => $client);
                    $trx = $client->smart_payment(
                        currency          => $currency,
                        amount            => $signed_amount,
                        payment_type      => $payment_type,
                        remark            => $statement_comment,
                        staff             => $clerk,
                        payment_processor => $payment_processor,
                        payment_method    => $payment_method,
                        transaction_type  => $transaction_type,
                        trace_id          => $trace_id,
                        transaction_id    => $transaction_id,
                        ($skip_validation ? () : (rule_engine => $rule_engine)),
                    );

                    if ($format eq 'doughflow' and $notify_client) {
                        my $brand           = request()->brand;
                        my $action_resolved = uc $action;
                        $action_resolved = 'WITHDRAWAL_REVERSAL' if $action_resolved eq 'REVERSAL';
                        my $event = get_event_by_type($action_resolved);

                        BOM::Platform::Event::Emitter::emit(
                            $event,
                            {
                                event_name => $event,
                                loginid    => $client->loginid,
                                properties => {
                                    type          => $action_resolved,
                                    statement_url => $brand->statement_url({language => $client->user->preferred_language}),
                                    live_chat_url => $brand->live_chat_url({language => $client->user->preferred_language}),
                                    amount        => $amount,
                                    currency      => $currency,
                                    clerk         => $clerk,
                                    map { $_ => $client->{$_} } qw[first_name last_name salutation]
                                }});
                    }
                }
            } catch ($e) {
                my $msg = ref $e eq 'HASH' ? $e->{message_to_client} : $e;
                $client_account_table .= construct_row_line(%row, error => "Transaction Error: $msg");
                return;
            }

            if ($action eq 'credit' and $payment_type =~ /^bank_money_transfer|external_cashier$/) {
                try {
                    $client->clear_status_and_sync_to_siblings('pa_withdrawal_explicitly_allowed');
                } catch {
                    $log->warn("Not able to unset payment agent explicity allowed flag for " . $client->loginid);
                }
            }
            $row{remark} = sprintf "OK transaction reference id: %d", $trx->{id};
        } else {
            $row{remark} = "OK to $action [Preview only]";
        }

        $client_account_table .= construct_row_line(%row);
        $client_to_be_processed{$login_id} = "$login_id,$action,$currency$amount,$statement_comment";
        $summary_amount_by_currency{$currency}{$action} += $amount;
    });

$client_account_table .= '</table>';

my $summary_table = '';
if (scalar @invalid_lines > 0) {
    $summary_table .= '<h3>Error(s) found, please correct the line(s) below</h3>' . '<table>' . '<tr><th>Error</th></tr>';

    foreach my $invalid_line (@invalid_lines) {
        $summary_table .= '<tr><td>' . $invalid_line . '</td></tr>';
    }
    $summary_table .= '</table>';
    $summary_table .= "<br><a class='link' href='javascript:history.go(-1);'>&laquo; Back</a><hr>";
}

if (%summary_amount_by_currency and scalar @invalid_lines == 0) {
    $summary_table .= qq[
      <style>
        table.summary { width: 30%; margin: 0 auto 12px auto; background-color: var(--bg-primary); border-collapse: collapse }
        table.summary th { border: 1px solid #777 }
        table.summary td { border: 1px solid #777; text-align: right }
      </style>
      <table class="summary"><caption>Currency Totals</caption><thead><tr><th>Currency</th><th>Credits</th><th>Debits</th><th>Reversals</th></tr></thead><tbody>
    ];
    foreach my $currency (sort keys %summary_amount_by_currency) {
        my $c   = encode_entities($currency);
        my $cr  = encode_entities(formatnumber('amount', $currency, $summary_amount_by_currency{$currency}{credit}   // 0));
        my $db  = encode_entities(formatnumber('amount', $currency, $summary_amount_by_currency{$currency}{debit}    // 0));
        my $rev = encode_entities(formatnumber('amount', $currency, $summary_amount_by_currency{$currency}{reversal} // 0));
        $summary_table .= "<tr><th>$c</th><td>$cr</td><td>$db</td><td>$rev</td></tr>";
    }
    $summary_table .= '</tbody></table>';
}

print $summary_table;
print $client_account_table;

if ($preview and @invalid_lines == 0) {
    print "<hr><div class=\"inner_bo_box\"><h3>Make Dual Control Code</h3><form action=\""
        . request()->url_for("backoffice/f_makedcc.cgi")
        . "\" method=\"post\" class=\"bo_ajax_form\">"
        . "<input type=hidden name=\"dcctype\" value=\"file_content\">"
        . "<input type=hidden name=\"broker\" value=\""
        . encode_entities($broker) . "\">"
        . "<input type=hidden name=\"l\" value=\"EN\">"
        . '<input type="hidden" name="purpose" value="batch clients payments" />'
        . "<input type=hidden name=\"file_location\" value=\""
        . encode_entities($payments_csv_file) . "\">"
        . "Make sure you check the above details before you make dual control code<br>"
        . "<br><label>Input a comment/reminder about this DCC:</label><input type=text size=50 name=reminder data-lpignore='true' />"
        . "<label>Type of transaction:</label><select name='transtype'>"
        . "<option value='BATCHACCOUNT'>Batch Account</option><option value='BATCHDOUGHFLOW'>Batch Doughflow</option>"
        . "</select>"
        . "<br /><br /><input type=\"submit\" class='btn btn--primary' value='Make Dual Control Code (by "
        . encode_entities($clerk) . ")'>"
        . "</form></div>";

    print qq[<hr><div class="inner_bo_box">
        <h3>Confirm credit/debit clients</h3>
        <form onsubmit="confirm('Are you sure?')">
            <input type="hidden" name="payments_csv_file" value="$payments_csv_file"/>
            <input type="hidden" name="skip_validation" value="] . encode_entities($skip_validation) . qq["/>
            <input type="hidden" name="notify_client" value="] . encode_entities($notify_client) . qq["/>
            <label>Control Code:</label><input type=text name=DCcode required size=16 data-lpignore='true' />
            <label>Type of transaction:</label>
            <select name="transtype">
				<option value="BATCHACCOUNT">Batch Account</option><option value="BATCHDOUGHFLOW">Batch Doughflow</option>
            </select>
            <button type="submit" class="btn btn--primary" name="confirm" value="$format">Confirm (Do it for real!)</button>
         </form></div>];
} elsif (not $preview and $confirm and scalar(keys %client_to_be_processed) > 0) {
    my @clients_has_been_processed = values %client_to_be_processed;
    unshift @clients_has_been_processed, 'These clients have been debited/credited using the backoffice batch debit/credit tool by ' . $clerk;

    my $msg = $now->datetime . " $transtype batch transactions done by clerk=$clerk (DCcode=$control_code) $ENV{REMOTE_ADDR}";
    BOM::User::AuditLog::log($msg, '', $clerk);
    Path::Tiny::path(BOM::Backoffice::Config::config()->{log}->{deposit})->append_utf8($msg);

    my $brand = request()->brand;
    send_email({
        'from'    => $brand->emails('support'),
        'to'      => $brand->emails('payments_notification'),
        'subject' => 'Batch debit/credit client account on ' . Date::Utility->new->date_ddmmmyy,
        'message' => \@clients_has_been_processed,
    });
}

sub construct_row_line {
    my %args = @_;

    $args{$_} = encode_entities($args{$_}) for keys %args;
    my $notes = $args{remark};
    my $class = 'success';

    if ($args{error}) {
        $notes = $args{error};
        $class = 'error';
    }

    $args{$_} ||= '&nbsp;' for keys %args;

    return qq[ <tr>
        <td><a name="ln$args{line_number}">$args{line_number}</td>
        <td>$args{login_id}</td>
        <td>$args{name}</td>
        <td>$args{action}</td>
        <td>$args{payment_type}</td>
        <td>$args{trace_id}</td>
        <td>$args{payment_processor}</td>
        <td>$args{payment_method}</td>
        <td>$args{currency}</td>
        <td>$args{amount}</td>
        <td>$args{comment}</td>
        <td>$args{transaction_id}</td>
        <td class="$class">$notes</td>
    </tr>];
}

sub read_csv_row_and_callback {
    my $csv_lines = shift;
    my $callback  = shift;

    foreach my $line (@{$csv_lines}) {
        chomp $line;
        $line =~ s/"//g;
        my (@row_values) = split ',', $line;

        &$callback(@row_values);
    }
    return;
}

sub _doughflow_tx_statement_comment {
    my ($transaction_type, $trace_id, $payment_method, $payment_processor, $transaction_id) = @_;

    my $comment = "DoughFlow $transaction_type trace_id=$trace_id created_by=INTERNET payment_method=$payment_method";

    $comment .= " payment_processor=$payment_processor" if (defined $payment_processor);

    $comment .= " transaction_id=$transaction_id" if (defined $transaction_id);

    return $comment;
}

code_exit_BO();
