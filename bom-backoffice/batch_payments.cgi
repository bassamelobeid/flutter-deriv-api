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
}

my $payment_lines = [Path::Tiny::path($payments_csv_file)->lines_utf8];
print_summary($payment_lines, $format) unless $confirm;

my ($transtype, $control_code);
if ($confirm) {
    unlink $payments_csv_file;

    $control_code = $cgi->param('DCcode');
    $transtype    = $cgi->param('transtype');

    my $error = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $transtype
        })->validate_batch_payment_control_code($control_code, $payment_lines);
    if ($error) {
        print encode_entities($error->get_mesg());
        code_exit_BO();
    }

    read_csv_and_trigger_event($payment_lines, $format, $clerk, $skip_validation, $notify_client, $staff_limit);

    print("All Clients Processed. Payment Events have been created. Check logs/email inbox for any failures.");

    my $msg = $now->datetime . " $transtype batch transactions done by clerk=$clerk (DCcode=$control_code) $ENV{REMOTE_ADDR}";
    BOM::User::AuditLog::log($msg, '', $clerk);
    Path::Tiny::path(BOM::Backoffice::Config::config()->{log}->{deposit})->append_utf8($msg);

}

sub print_summary {
    my ($csv_lines, $format) = @_;
    my $line_number = 0;
    my @hdgs        = (
        'Line Number', 'Login Id', 'Name', 'Debit/credit/reversal', 'Payment Type', 'Trace ID',
        'Payment Processor',
        'Payment Method',
        'Currency', 'Amount', 'Comment', 'Transaction ID'
    );

    my $client_account_table = '<h3>Batch details (Pls note the Preview is limited to only 500 lines)</h3><table class="border full-width">' . '<tr>'
        . join('', map { "<th>$_</th>" } @hdgs) . '</tr>';

    foreach my $line (@$csv_lines) {
        chomp $line;
        $line =~ s/"//g;
        my (@row_values) = split ',', $line;
        my $cols_found   = scalar @row_values;
        my (
            $login_id, $action, $payment_type,      $payment_processor, $payment_method, $trace_id,
            $currency, $amount, $statement_comment, $transaction_id,    $cols_expected,  $transaction_type
        );

        if ($format eq 'doughflow') {
            ($login_id, $action, $trace_id, $payment_processor, $payment_method, $currency, $amount, $transaction_id) = @row_values;
            $payment_type = 'external_cashier';
            if (($action // '') eq 'credit') {
                $cols_expected = 8;
            } else {
                $cols_expected = 7;
            }
        } else {
            ($login_id, $action, $payment_type, $currency, $amount, $statement_comment) = @row_values;
            $cols_expected = 6;
        }
        ++$line_number;
        last if $line_number > 500;
        my $client = BOM::User::Client->new({loginid => $login_id}) or die "Invalid loginid: $login_id\n";
        my %row    = (
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
        $client_account_table .= construct_row_line(%row);
    }
    $client_account_table .= '</table>';
    print $client_account_table;

}

sub construct_row_line {
    my %args = @_;

    $args{$_} = encode_entities($args{$_}) for keys %args;
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
    </tr>];
}

sub read_csv_and_trigger_event {
    my ($payment_lines, $format, $staff, $skip_validation, $notify_client, $staff_limit) = @_;

    BOM::Platform::Event::Emitter::emit(
        'batch_payment',
        {
            event_name => 'batch_payment',
            properties => {
                csv_lines       => $payment_lines,
                format          => $format,
                staff           => $staff,
                skip_validation => $skip_validation,
                notify_client   => $notify_client,
                payment_limits  => $staff_limit
            }});
}

code_exit_BO();
