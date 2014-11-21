#!/usr/bin/perl
package main;

use strict;
use warnings;

use BOM::Utility::Format::Numbers qw(to_monetary_number_format roundnear);

use f_brokerincludeall;

use BOM::Platform::Data::Persistence::DataMapper::Payment;
use BOM::Platform::Transaction;
use Path::Tiny;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Context;
use BOM::Platform::Plack qw( PrintContentType );
system_initialize();

PrintContentType();
BrokerPresentation('Batch Credit/Debit to Clients Accounts');

my $cgi               = new CGI;
my $broker            = request()->broker->code;
my $clerk             = BOM::Platform::Auth0::from_cookie()->{nickname};
my $confirm           = $cgi->param('confirm');
my $preview           = $cgi->param('preview');
my $payments_csv_fh   = $cgi->upload('payments_csv');
my $payments_csv_file = $cgi->param('payments_csv_file') || sprintf '/tmp/batch_payments_%d.csv', rand(1_000_000);
my $format            = $confirm || $preview || die "either preview or confirm";

Bar('Batch Credit/Debit to Clients Accounts');

if ($preview) {
    open my $fh, ">$payments_csv_file" or die "writing upload: $!";
    while (<$payments_csv_fh>) {
        s/\s*$//;    # remove various combos of unix/windows rec-separators
        printf $fh "$_\n";
    }
    close $fh;
}

my @payment_lines = Path::Tiny::path($payments_csv_file)->lines;

if ($confirm) {

    unlink $payments_csv_file;

    unless (BOM::Platform::Runtime->instance->app_config->system->on_development) {

        # Check Dual Control Code
        my $fellow_staff = $cgi->param('DCstaff');
        my $control_code = $cgi->param('DCcode');

        if ($fellow_staff eq $clerk) {
            print "ERROR: fellow staff name for dual control code cannot be yourself!";
            code_exit_BO();
        }

        my $validcode = dual_control_code_for_file_content(
            $fellow_staff,
            BOM::Platform::Context::request()->bo_cookie->password,
            BOM::Utility::Date->new->date_ddmmmyy,
            join("\n", @payment_lines),
        );

        if (substr(uc($control_code), 0, 5) ne substr(uc($validcode), 0, 5)) {
            print "SORRY, the Dual Control Code $control_code is invalid. Please check the csv file, fellow staff name and date of DCC.";
            code_exit_BO();
        }

        #check if control code already used
        my $count    = 0;
        my $log_file = File::ReadBackwards->new("/var/log/fixedodds/fmanagerconfodeposit.log");
        while ((defined(my $l = $log_file->readline)) and ($count++ < 200)) {
            if ($l =~ /DCcode\=$control_code/i) {
                print 'ERROR: this control code has already been used today!';
                code_exit_BO();
            }
        }

        if (not ValidDualControlCode($control_code)) {
            print 'ERROR: invalid dual control code!';
            code_exit_BO();
        }
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
            $cols_found == $cols_expected                                           or $error = "Found $cols_found fields, needed $cols_expected for $format payments", last;
            $client = eval { BOM::Platform::Client->new({loginid => $login_id}) }   or $error = ($@ || 'No such client'), last;
            $currency ne $client->currency                                          and $error = "client does not trade in currency [$currency]", last;
            $action !~ /^(debit|credit)$/                                           and $error = "Invalid transaction type [$action]", last;
            $amount !~ /^\d+\.?\d?\d?$/ || $amount == 0                             and $error = "Invalid amount [$amount]", last;
            $amount > 1000                                                          and $error = 'Amount not allowed to exceed 1000',  last;
            !$statement_comment                                                     and $error = 'Statement comment can not be empty', last;

            if ($action eq 'debit') {
                my $balance = $client->default_account->balance;
                if ($amount > $balance) {
                    $error = "Client does not have enough balance to debit. Client current balance is $currency$balance";
                    last;
                }
            }

            # check pontential duplicate entry
            my $payment_mapper = BOM::Platform::Data::Persistence::DataMapper::Payment->new({
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
                $error = "Same transaction found in client account. Please check [transaciton id:" . $duplicate_record . ']';
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
            if (not BOM::Platform::Transaction->freeze_client($login_id)) {
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
                );
            } or $err = $@;
            BOM::Platform::Transaction->unfreeze_client($login_id);

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
      . "Make sure you check the above details before you make dual control code"
      . "<br />Input a comment/reminder about this DCC: <input type=text size=50 name=reminder>"
      . "<br /><input type=\"submit\" value='Make Dual Control Code (by $clerk)'>"
      . "</form></div>";

    print qq[<div class="inner_bo_box"><h2>Confirm credit/debit clients</h2>
        <form onsubmit="confirm('Are you sure?')">
         <input type="hidden" name="payments_csv_file" value="$payments_csv_file"/>
         <table border=0 cellpadding=1 cellspacing=1><tr><td bgcolor=FFFFEE><font color=blue>
				<b>DUAL CONTROL CODE</b>
				<br>Fellow staff name: <input type=text name=DCstaff required size=8>
				Control Code: <input type=text name=DCcode required size=16>
				</td></tr></table>
         <button type="submit" name="confirm" value="$format">Confirm (Do it for real!)</button>
         </form></div>];
} elsif (not $preview and $confirm and scalar(keys %client_to_be_processed) > 0) {
    my @clients_has_been_processed = values %client_to_be_processed;
    unshift @clients_has_been_processed, 'These clients have been debited/credited using the backoffice batch debit/credit tool by ' . $clerk;

    send_email({
            'from'    => BOM::Platform::Context::request()->website->config->get('customer_support.email'),
            'to'      => BOM::Platform::Runtime->instance->app_config->accounting->email,
            'subject' => 'Batch debit/credit client account on ' . BOM::Utility::Date->new->date_ddmmmyy,
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

code_exit_BO();
