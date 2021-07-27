#!/usr/bin/env perl 
use strict;
use warnings;

use Path::Tiny;
use Syntax::Keyword::Try;

use Date::Utility;
use Brands;
use HTML::Entities;
use Format::Util::Numbers qw/formatnumber/;
use Scalar::Util qw(looks_like_number);
use Scope::Guard;

use LandingCompany::Registry;

use BOM::Database::DataMapper::Payment;
use BOM::Database::ClientDB;
use BOM::Platform::Email qw(send_email);
use BOM::DualControl;
use BOM::Backoffice::Config;
use BOM::User::AuditLog;
use BOM::User::Client;
use BOM::Config::Runtime;

use Log::Any::Adapter qw(Stderr), log_level => 'debug';
use Log::Any qw($log);

use Getopt::Long;

GetOptions(
    's|staff=s'       => \my $staff,
    'dc|dccode=s'     => \my $dc_code,
    'tt|trans_type=s' => \my $trans_type,
    'f|format=s'      => \my $format,
    'b|broker=s'      => \my $broker,
    'p|preview'       => \my $preview,
) or die 'invalid parameters';

# trans_type and format are likely affiliate_reward
die 'need staff' unless $staff;
#die 'need DC'               unless $dc_code;
die 'need transaction type' unless $trans_type;
die 'need format'           unless $format;
die 'need broker'           unless $broker;

$broker = uc $broker;

my @payment_lines = do {
    my $file = shift @ARGV or die 'need a file';
    my @data = Path::Tiny::path($file)->lines_utf8;
    s/\s+$// for @data;
    @data;
};
$log->infof('%d payments to make for %s', 0 + @payment_lines, $broker);

#if (
#    my $error = BOM::DualControl->new({
#            staff           => $staff,
#            transactiontype => $trans_type
#        }
#    )->validate_batch_payment_control_code($dc_code, 0 + @payment_lines))
#{
#    die $error->get_mesg;
#}

my $now  = Date::Utility->new;
my @hdgs = (
    'Line Number',       'Login Id', 'Name',   'debit/credit', 'Payment Type',   'Trace ID',
    'Payment Processor', 'Currency', 'Amount', 'Comment',      'Transaction ID', 'Elapsed',
    'Notes'
);

my $client_account_table =
    '<table border="1" width="100%" bgcolor="#ffffff" style="border-collapse:collapse;margin-bottom:20px"><caption>Batch Credit/Debit details</caption>'
    . '<tr>'
    . join('', map { "<th>$_</th>" } @hdgs) . '</tr>';

my %summary_amount_by_currency;
my @invalid_lines;
my $line_number;
my %client_to_be_processed;
my $is_transaction_id_required = 0;
read_csv_row_and_callback(
    \@payment_lines,
    sub {
        my $cols_found = @_;
        my (
            $login_id, $action, $payment_type,      $payment_processor, $trace_id,
            $currency, $amount, $statement_comment, $transaction_id,    $cols_expected
        );
        if ($format eq 'doughflow') {
            ($login_id, $action, $trace_id, $payment_processor, $currency, $amount, $statement_comment, $transaction_id) = @_;
            $payment_type = 'external_cashier';
            if ($action eq 'credit' and $statement_comment !~ 'DoughFlow withdrawal_reversal') {
                $is_transaction_id_required = 1;
                $cols_expected              = 8;
            } else {
                $is_transaction_id_required = 0;
                $cols_expected              = 7;
            }
        } else {
            ($login_id, $action, $payment_type, $currency, $amount, $statement_comment) = @_;
            $cols_expected = 6;
        }
        $log->infof('Processing %s for %s as %s, %s %s comment %s', $action, $login_id, $payment_type, $currency, $amount, $statement_comment);

        $line_number++;

        my $client;
        my $error;
        my %row = (
            line_number       => $line_number,
            login_id          => $login_id,
            action            => $action,
            payment_type      => $payment_type,
            currency          => $currency,
            amount            => $amount,
            comment           => $statement_comment,
            payment_processor => $payment_processor,
            trace_id          => $trace_id,
        );

        my $start = Time::HiRes::time;
        try {
            {
                my $curr_regex = LandingCompany::Registry::get_currency_type($currency) eq 'fiat' ? '^\d*\.?\d{1,2}$' : '^\d*\.?\d{1,8}$';
                $amount = formatnumber('price', $currency, $amount) if looks_like_number($amount);

                # TODO fix this critic
                ## no critic (ProhibitCommaSeparatedStatements, ProhibitMixedBooleanOperators)
                $cols_found == $cols_expected or $error = "Found $cols_found fields, needed $cols_expected for $format payments", last;
                $action !~ /^(debit|credit)$/          and $error = "Invalid transaction type [$action]", last;
                $amount !~ $curr_regex || $amount == 0 and $error = "Invalid amount [$amount]",           last;
                !$statement_comment and $error = 'Statement comment can not be empty', last;
                try {
                    $client = BOM::User::Client->new({loginid => $login_id});
                    unless ($client) {
                        $error = 'No such client';
                        last;
                    }
                } catch ($e) {
                    $error = $e;
                    last;
                }
                $row{name} = $client->full_name;
                my $signed_amount = $action eq 'debit' ? $amount * -1 : $amount;

                if ($is_transaction_id_required) {
                    $error = "Transaction id is mandatory for doughflow credit"
                        if not $transaction_id or $transaction_id !~ '\w+';
                    $error =
                        "Transaction id provided does not match with one provided in comment (it should be in format like: transaction_id=33232)."
                        if $statement_comment !~ /transaction_id=$transaction_id/;
                }

                try { $client->validate_payment(currency => $currency, amount => $signed_amount) } catch ($e) {
                    $error = $e
                };
                last if $error;

                # check pontential duplicate entry
                my $payment_mapper = BOM::Database::DataMapper::Payment->new({
                    client_loginid => $login_id,
                    currency_code  => $currency,
                });

                chomp($statement_comment);
                if (0) {
                    # Skip the duplicate processing: it is slow. it is also unnecessary for dormant fees,
                    # since there's no TraceID to look for.
                    if (
                        my $duplicate_record = $payment_mapper->get_transaction_id_of_account_by_comment({
                                amount  => ($action eq 'debit' ? $amount * -1 : $amount),
                                comment => $statement_comment
                            }))
                    {
                        $error = "Same transaction found in client account. Check [transaction id: $duplicate_record]";
                        last;
                    }
                }
            }

            $row{transaction_id} = $transaction_id if $is_transaction_id_required;

            if ($error) {
                $client_account_table .= construct_row_line(%row, error => $error);
                push @invalid_lines, qq[<a href="#ln$line_number">Invalid line $line_number</a> : ] . encode_entities($error);
                return;
            }

            unless ($preview) {
                my $client_db = BOM::Database::ClientDB->new({
                    client_loginid => $login_id,
                });

                my $signed_amount = $amount;
                $signed_amount *= -1 if $action eq 'debit';
                my $err;
                my $trx;
                try {
                    $log->infof('Making payment for %s %s as %s from %s (%s %s)',
                        $currency, $signed_amount, $payment_type, $staff, $payment_processor, $trace_id);
                    $trx = $client->smart_payment(
                        currency          => $currency,
                        amount            => $signed_amount,
                        payment_type      => $payment_type,
                        remark            => $statement_comment,
                        staff             => $staff,
                        payment_processor => $payment_processor,
                        trace_id          => $trace_id,
                    );
                } catch ($e) {
                    $err = $e;
                    $log->errorf('%s failed - %s', $login_id, $err,);
                };
                if ($err) {
                    $client_account_table .= construct_row_line(%row, error => "Transaction Error: $err");
                    return;
                } elsif ($action eq 'credit' and $payment_type !~ /^affiliate_reward|arbitrary_markup|free_gift$/) {
                    # need to set this for batch payment in case of credit only
                    try {
                        $client->payment_agent_withdrawal_expiration_date(Date::Utility->today->date_yyyymmdd);
                        $client->save;
                    } catch ($e) {
                        warn "Not able to set payment agent expiration date for " . $client->loginid;
                    };
                }
                $row{remark} = sprintf "OK transaction reference id: %d", $trx->{id};
            } else {
                $row{remark} = "OK to $action [Preview only]";
            }

        } catch ($e) {
            my $err = $e;
            $log->errorf('Failed on %s - %s', $login_id, $err);
            $row{remark} = "Failed - $err";
        };
        my $elapsed = Time::HiRes::time - $start;
        $log->infof('%.2fs - %s', $elapsed, $row{remark});
        $client_account_table .= construct_row_line(%row, elapsed => $elapsed);
        # If this was slow, maybe the database is hurting... so slow down our rate even further
        if ($elapsed > 0.5) {
            warn "took $elapsed seconds - sleeping for a bit\n";
            sleep 7;
        } else {
            Time::HiRes::sleep 0.05;
        }
        $client_to_be_processed{$login_id} = "$login_id,$action,$currency$amount,$statement_comment";
        $summary_amount_by_currency{$currency}{$action} += $amount;
    });

$client_account_table .= '</table>';

my $summary_table = '';
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
        my $c  = encode_entities($currency);
        my $cr = encode_entities(formatnumber('amount', $currency, $summary_amount_by_currency{$currency}{credit} // 0));
        my $db = encode_entities(formatnumber('amount', $currency, $summary_amount_by_currency{$currency}{debit}  // 0));
        $summary_table .= "<tr><th>$c</th><td>$cr</td><td>$db</td></tr>";
    }
    $summary_table .= '</table>';
}

my $html = path('/var/lib/binary/payments/' . $broker . '.html');
$html->spew_utf8($summary_table);
$html->append_utf8($client_account_table) if length $client_account_table;

if ($summary_table or %client_to_be_processed) {
    my @clients_has_been_processed = values %client_to_be_processed;
    unshift @clients_has_been_processed, 'These clients have been debited/credited using the backoffice batch debit/credit tool by ' . $staff;

    my $msg = $now->datetime . " $trans_type batch transactions done by clerk=$staff (DCcode=$dc_code)";
    BOM::User::AuditLog::log($msg, '', $staff);
    Path::Tiny::path(BOM::Backoffice::Config::config()->{log}->{deposit})->append_utf8($msg);

    my $brand = Brands->new(name => 'binary');
    $log->infof('Sending email');
    send_email({
        'from' => $brand->emails('support'),
        'to'   =>
            'tom@binary.com,jennice@binary.com,evelyn@binary.com,manjula@binary.com,syamilah@binary.com,vanitha@binary.com,thevathaasan@binary.com,logeetha@binary.com,'
            . $brand->emails('accounting'),
        'subject'  => 'Batch debit ' . $broker . ' client accounts for dormant fees on ' . Date::Utility->new->date_ddmmmyy,
        'message'  => \@clients_has_been_processed,
        attachment => ["$html"],
    });
}

sub construct_row_line {
    my %args = @_;

    map { $args{$_} = encode_entities($args{$_}) } keys %args;
    my $notes = $args{error} || $args{remark};
    my $color = $args{error} ? 'red' : 'green';
    $args{$_} ||= '&nbsp;' for keys %args;
    my $transaction_id = $args{transaction_id} // '';

    return qq[ <tr>
        <td><a name="ln$args{line_number}">$args{line_number}</td>
        <td>$args{login_id}</td>
        <td>$args{name}</td>
        <td>$args{action}</td>
        <td>$args{payment_type}</td>
        <td>$args{trace_id}</td>
        <td>$args{payment_processor}</td>
        <td>$args{currency}</td>
        <td>$args{amount}</td>
        <td>$args{comment}</td>
        <td>$transaction_id</td>
        <td>$args{elapsed}</td>
        <td style="color:$color">$notes</td>
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

1;
