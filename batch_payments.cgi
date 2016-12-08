#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Path::Tiny;
use Try::Tiny;
use Date::Utility;
use Format::Util::Numbers qw(to_monetary_number_format roundnear);

use f_brokerincludeall;
use BOM::Database::DataMapper::Payment;
use BOM::Database::ClientDB;
use BOM::Platform::Email qw(send_email);
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::DualControl;
use BOM::System::AuditLog;
use BOM::System::Config;
use BOM::Backoffice::Sysinit ();
use BOM::Platform::Runtime;
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('Batch Credit/Debit to Clients Accounts');

if (BOM::Platform::Runtime->instance->app_config->system->suspend->system) {
    print "ERROR: Sytem is suspended";
    code_exit_BO();
}

my $cgi               = CGI->new;
my $broker            = request()->broker_code;
my $clerk             = BOM::Backoffice::Auth0::from_cookie()->{nickname};
my $confirm           = $cgi->param('confirm');
my $preview           = $cgi->param('preview');
my $payments_csv_file = $cgi->param('payments_csv_file') || sprintf '/tmp/batch_payments_%d.csv', rand(1_000_000);
my $skip_validation   = $cgi->param('skip_validation') || 0;
my $format            = $confirm || $preview || die "either preview or confirm";
my $now               = Date::Utility->new;

Bar('Batch Credit/Debit to Clients Accounts');

if ($preview) {
    my $payments_csv_fh = $cgi->upload('payments_csv');
    binmode $payments_csv_fh, ':encoding(UTF-8)';
    open my $fh, '>:encoding(UTF-8)', $payments_csv_file or die "writing upload: $!";
    while (<$payments_csv_fh>) {
        s/\s*$//;    # remove various combos of unix/windows rec-separators
        printf $fh "$_\n";
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
        })->validate_batch_payment_control_code($control_code, scalar @payment_lines);
    if ($error) {
        print $error->get_mesg();
        code_exit_BO();
    }
}

my @hdgs = ('Line Number', 'Login Id', 'Name', 'debit/credit', 'Payment Type', 'Trace ID', 'Payment Processor', 'Currency', 'Amount', 'Comment');
my $client_account_table =
    '<table border="1" width="100%" bgcolor="#ffffff" style="border-collapse:collapse;margin-bottom:20px"><caption>Batch Credit/Debit details</caption>'
    . '<tr>'
    . join('', map { "<th>$_</th>" } @hdgs) . '</tr>';

my %summary_amount_by_currency;
my @invalid_lines;
my $line_number;
my %client_to_be_processed;
read_csv_row_and_callback(
    \@payment_lines,
    sub {
        my $cols_found = @_;
        my ($login_id, $action, $payment_type, $payment_processor, $trace_id, $currency, $amount, $statement_comment, $cols_expected);
        if ($format eq 'doughflow') {
            ($login_id, $action, $trace_id, $payment_processor, $currency, $amount, $statement_comment) = @_;
            $payment_type  = 'external_cashier';
            $cols_expected = 7;
        } else {
            ($login_id, $action, $payment_type, $currency, $amount, $statement_comment) = @_;
            $cols_expected = 6;
        }

        $line_number++;

        my $client;
        my $error;
        {
            $cols_found == $cols_expected or $error = "Found $cols_found fields, needed $cols_expected for $format payments", last;
            $action !~ /^(debit|credit)$/ and $error = "Invalid transaction type [$action]", last;
            $amount !~ /^\d+\.?\d?\d?$/ || $amount == 0 and $error = "Invalid amount [$amount]", last;
            !$statement_comment and $error = 'Statement comment can not be empty', last;
            $client = eval { Client::Account->new({loginid => $login_id}) } or $error = ($@ || 'No such client'), last;
            my $signed_amount = $action eq 'debit' ? $amount * -1 : $amount;

            unless ($skip_validation) {
                try { $client->validate_payment(currency => $currency, amount => $signed_amount) } catch { $error = $_ };
                last if $error;
            }

            # check pontential duplicate entry
            my $payment_mapper = BOM::Database::DataMapper::Payment->new({
                client_loginid => $login_id,
                currency_code  => $currency,
            });

            chomp($statement_comment);
            if (
                my $duplicate_record = $payment_mapper->get_transaction_id_of_account_by_comment({
                        amount => ($action eq 'debit' ? $amount * -1 : $amount),
                        comment => $statement_comment
                    }))
            {
                $error = "Same transaction found in client account. Check [transaciton id: $duplicate_record]";
                last;
            }
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
            trace_id          => $trace_id,
        );

        if ($error) {
            $client_account_table .= construct_row_line(%row, error => $error);
            push @invalid_lines, qq[<a href="#ln$line_number">Invalid line $line_number</a> : $error];
            return;
        }

        if (not $preview and $confirm and @invalid_lines == 0) {
            my $client_db = BOM::Database::ClientDB->new({
                client_loginid => $login_id,
            });

            if (not $client_db->freeze) {
                die "Account stuck in previous transaction $login_id";
            }
            my $signed_amount = $amount;
            $signed_amount *= -1 if $action eq 'debit';
            my $err;
            my $trx = eval {
                $client->smart_payment(
                    currency          => $currency,
                    amount            => $signed_amount,
                    payment_type      => $payment_type,
                    remark            => $statement_comment,
                    staff             => $clerk,
                    payment_processor => $payment_processor,
                    trace_id          => $trace_id,
                    ($skip_validation ? (skip_validation => 1) : ()),
                );
            } or $err = $@;
            $client_db->unfreeze;

            if ($err) {
                $client_account_table .= construct_row_line(%row, error => "Transaction Error: $err");
                return;
            }
            $row{remark} = sprintf "OK transaction reference id: %d", $trx->id;

        } else {
            $row{remark} = "OK to $action [Preview only]";
        }

        $client_account_table .= construct_row_line(%row);
        $client_to_be_processed{$login_id} = "$login_id,$action,$currency$amount,$statement_comment";
        $summary_amount_by_currency{$currency}{$action} += $amount;
    });

$client_account_table .= '</table>';

my $summary_table;
if (scalar @invalid_lines > 0) {
    $summary_table .=
          '<table border="1" width="100%" bgcolor="#ffffff" style="border-collapse:collapse;margin-bottom:20px;color:red;">'
        . '<caption>Error(s) found, please correct the line(s) below</caption>'
        . '<tr><th>Error</th></tr>';

    foreach my $invalid_line (@invalid_lines) {
        $summary_table .= '<tr><td>' . $invalid_line . '</td></tr>';
    }
    $summary_table .= '</table>';
    $summary_table .= "<center><a href='javascript:history.go(-1);'>Back</a></center><br /><br />";
}

if (%summary_amount_by_currency and scalar @invalid_lines == 0) {
    $summary_table .= qq[
      <style>
        table.summary { width: 30%; margin: 0 auto 12px auto; background-color: #fff; border-collapse: collapse }
        table.summary th { border: 1px solid #777 }
        table.summary td { border: 1px solid #777; text-align: right }
      </style>
      <table class="summary"><caption>Currency Totals</caption><tr><th>Currency</th><th>Credits</th><th>Debits</th></tr>
    ];
    foreach my $currency (sort keys %summary_amount_by_currency) {
        my $cr = to_monetary_number_format(roundnear(0.1, $summary_amount_by_currency{$currency}{credit}));
        my $db = to_monetary_number_format(roundnear(0.1, $summary_amount_by_currency{$currency}{debit}));
        $summary_table .= "<tr><th>$currency</th><td>$cr</td><td>$db</td></tr>";
    }
    $summary_table .= '</table>';
}

print $summary_table;
print $client_account_table;

if ($preview and @invalid_lines == 0) {
    print "<div class=\"inner_bo_box bo_ajax_form\"><h2>Make Dual Control Code</h2><form action=\""
        . request()->url_for("backoffice/f_makedcc.cgi")
        . "\" method=\"post\">"
        . "<input type=hidden name=\"dcctype\" value=\"file_content\">"
        . "<input type=hidden name=\"broker\" value=\"$broker\">"
        . "<input type=hidden name=\"l\" value=\"EN\">"
        . '<input type="hidden" name="purpose" value="batch clients payments" />'
        . "<input type=hidden name=\"file_location\" value=\"$payments_csv_file\">"
        . "Make sure you check the above details before you make dual control code<br>"
        . "<br>Input a comment/reminder about this DCC: <input type=text size=50 name=reminder>"
        . "Type of transaction: <select name='transtype'>"
        . "<option value='BATCHACCOUNT'>Batch Account</option><option value='BATCHDOUGHFLOW'>Batch Doughflow</option>"
        . "</select>"
        . "<br /><input type=\"submit\" value='Make Dual Control Code (by $clerk)'>"
        . "</form></div>";

    print qq[<div class="inner_bo_box"><h2>Confirm credit/debit clients</h2>
        <form onsubmit="confirm('Are you sure?')">
         <input type="hidden" name="payments_csv_file" value="$payments_csv_file"/>
         <input type="hidden" name="skip_validation" value="$skip_validation"/>
         <table border=0 cellpadding=1 cellspacing=1><tr><td bgcolor=FFFFEE><font color=blue>
				<b>DUAL CONTROL CODE</b>
				Control Code: <input type=text name=DCcode required size=16>
				Type of transaction: <select name="transtype">
				<option value="BATCHACCOUNT">Batch Account</option><option value="BATCHDOUGHFLOW">Batch Doughflow</option>
				</select>
				</td></tr></table>
         <button type="submit" name="confirm" value="$format">Confirm (Do it for real!)</button>
         </form></div>];
} elsif (not $preview and $confirm and scalar(keys %client_to_be_processed) > 0) {
    my @clients_has_been_processed = values %client_to_be_processed;
    unshift @clients_has_been_processed, 'These clients have been debited/credited using the backoffice batch debit/credit tool by ' . $clerk;

    my $msg = $now->datetime . " $transtype batch transactions done by clerk=$clerk (DCcode=$control_code) $ENV{REMOTE_ADDR}";
    BOM::System::AuditLog::log($msg, '', $clerk);
    Path::Tiny::path("/var/log/fixedodds/fmanagerconfodeposit.log")->append_utf8($msg);

    send_email({
        'from'    => BOM::System::Config::email_address('support'),
        'to'      => BOM::System::Config::email_address('accounting'),
        'subject' => 'Batch debit/credit client account on ' . Date::Utility->new->date_ddmmmyy,
        'message' => \@clients_has_been_processed,
    });
}

sub construct_row_line {
    my %args = @_;

    my $notes = $args{error} || $args{remark};
    my $color = $args{error} ? 'red' : 'green';
    $args{$_} ||= '&nbsp;' for keys %args;
    return qq[ <tr>
        <td><a name="ln$args{line_number}">$args{line_number}</td>
        <td>$args{login_id}</td>
        <td>$args{name}</td>
        <td>$args{action}</td>
        <td>$args{payment_type}</td>
        <td>$args{trace_id}</td>
        <td>$args{payment_processor}</td>
        <td>$args{currency} $args{amount}</td>
        <td>$args{comment}</td>
        <td style="color:$color">$notes</td>
    </tr>];
}

sub read_csv_row_and_callback {
    my $csv_lines = shift;
    my $callback  = shift;

    foreach my $line (@{$csv_lines}) {
        $line =~ s/"//g;
        my (@row_values) = split ',', $line;

        &$callback(@row_values);
    }
}

code_exit_BO();
