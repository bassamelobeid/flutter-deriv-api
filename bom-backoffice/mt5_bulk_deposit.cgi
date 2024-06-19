#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Path::Tiny;
use Syntax::Keyword::Try;
use Date::Utility;
use Scalar::Util qw(looks_like_number);
use BOM::Database::ClientDB;
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit      ();
use BOM::Backoffice::Auth;
use BOM::Config::Runtime;
use BOM::Config;
use BOM::User::Client;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use HTTP::Tiny;
use YAML::XS                 qw(LoadFile);
use LandingCompany::Registry qw(get_currency_type);
use HTML::Entities           qw(encode_entities);
use BOM::DualControl;

sub http {
    HTTP::Tiny->new(timeout => 20);
}

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('Bulk deposit to MT5 accounts');

if (BOM::Config::Runtime->instance->app_config->system->suspend->payments) {
    code_exit_BO('ERROR: Payments are suspended.');
}

my $cgi               = CGI->new;
my $preview           = $cgi->param('preview');
my $confirm           = $cgi->param('confirm');
my $payments_csv_file = $cgi->param('payments_csv_file') || sprintf '/tmp/batch_payments_%d.csv', rand(1_000_000);
my $payments_csv      = $cgi->param('payments_csv');
my $dc_code           = $cgi->param('DCcode');

my ($line_number, @invalid_lines, @accounts_to_process, @added_transactions, @accounts);
my $summary_table = '';
my $mt5_config    = BOM::Config::mt5_webapi_config();

my @hdgs = (
    'Line Number',
    'Deriv Account',
    'MT5 Account',
    'Transaction ID',
    'Transaction Time',
    'Amount',
    'Fee',
    'Currency',
    "Amount in USD",
    "Notes (preview only)"
);
my $client_account_table = '<h3>Batch details</h3><table class="border full-width">' . '<tr>' . join('', map { "<th>$_</th>" } @hdgs) . '</tr>';

our $mt5_proxy_url = $mt5_config->{mt5_http_proxy_url};
our $config        = '/etc/rmg/mt5webapi.yml';

Bar('Bulk deposit to MT5 accounts');

if ($preview) {
    my $payments_csv_fh = $cgi->upload('payments_csv');
    binmode $payments_csv_fh, ':encoding(UTF-8)';
    open my $fh, '>:encoding(UTF-8)', $payments_csv_file or die "writing upload: $!";
    while (my $line = <$payments_csv_fh>) {
        $line =~ s/\s*$//;    # remove various combos of unix/windows rec-separators
        $fh->print("$line\n");
    }
    close $fh;
}

if ($confirm) {
    my $received_accounts = $cgi->param('accounts_to_process');

    my $decoded_accounts = decode_json_utf8($received_accounts);
    my ($success_summary, $failed_summary);

    foreach (@$decoded_accounts) {
        my $deposit_op;
        try {
            $deposit_op = http->post(
                "$mt5_proxy_url/real_$_->{user_group}/UserBalanceChange",
                {
                    content => encode_json_utf8({
                            server  => "real_" . $_->{user_group},
                            login   => $_->{mt5_account},
                            balance => $_->{amount_in_usd},
                            comment => join('#', $_->{deriv_account}, $_->{transaction_id}),
                            type    => 'balance'
                        }
                    ),
                    headers => {
                        'Content-Type' => 'application/json',
                        'Accept'       => 'application/json',
                    }});
        } catch ($e) {
            $deposit_op->{content} = $e;
        }

        if ($deposit_op->{success} == 1) {
            $success_summary .=
                "<li style='color:green;'>Successfully transferred $_->{amount_in_usd} USD from $_->{deriv_account} to $_->{mt5_account} (transaction $_->{transaction_id})</li>";
        } else {
            $failed_summary .=
                "<li style='color:red;'>Failed to transfer $_->{amount_in_usd} USD from $_->{deriv_account} to $_->{mt5_account} (transaction $_->{transaction_id}) : $deposit_op->{content}</li>";
        }
    }

    print "<ul> $success_summary </ul>";
    print "<ul> $failed_summary </ul>";
}

my $staff         = BOM::Backoffice::Auth::get_staffname();
my @payment_lines = Path::Tiny::path($payments_csv_file)->lines_utf8;

print "<a class='link' href='javascript:history.go(-1);'>&laquo; Back</a><br><br>";

# Dual Control Code validation

foreach my $line (@payment_lines) {
    my @data = split /,/, $line;

    # MT5 account is always in the second position
    # If one MT5 account is used in multiple lines, we only need to validate it once
    push @accounts, 'MTR' . $data[1] unless grep { $_ eq 'MTR' . $data[1] } @accounts;
}

my $dcc_error = BOM::DualControl->new({
        staff           => $staff,
        transactiontype => 'TRANSFER',
    })->validate_batch_payment_control_code($dc_code, \@accounts);

if ($dcc_error) {
    print encode_entities($dcc_error->get_mesg());
    code_exit_BO();
}

read_csv_row(
    \@payment_lines,
    sub {
        my $cols_found = @_;
        my ($deriv_account, $mt5_account, $transaction_id, $transaction_time, $amount, $fee, $currency_code) = @_;
        my ($start_date, $end_date, $verify_transaction_db, $verify_transaction_mt5, $client, @errors);

        push @errors, "Duplicate transaction ID" if grep { $_ eq $transaction_id } @added_transactions;

        my $exchange_rate_params = {
            deriv_account    => $deriv_account,
            amount           => $amount,
            currency_code    => $currency_code,
            transaction_time => $transaction_time,
            fee              => $fee,
        };

        my $amount_in_usd = $currency_code eq 'USD' ? $amount : get_past_exchange_rate($exchange_rate_params);

        push @accounts_to_process,
            {
            deriv_account    => $deriv_account,
            mt5_account      => $mt5_account,
            transaction_id   => $transaction_id,
            transaction_time => $transaction_time,
            amount           => $amount,
            amount_in_usd    => $amount_in_usd,
            fee              => $fee,
            currency_code    => $currency_code,
            user_group       => get_mt5_group($mt5_account),
            };

        $line_number++;

        try {
            # We get the full day of the transaction (in epoch, starting from midnight) to ensure we look for the transaction
            # on MT5. Example: if transaction time is 2020-10-10 12:50:30, we will look for the transaction
            # between 2020-10-10 00:00:00 and 2020-10-11 00:00:00
            $start_date = Date::Utility->new($transaction_time)->date_yyyymmdd;
            $end_date   = Date::Utility->new($transaction_time)->plus_time_interval('1d')->date_yyyymmdd;
        } catch ($e) {
            push @errors, "Invalid time format";
        }

        if ($start_date and $end_date) {
            $verify_transaction_db  = verify_transaction_db($accounts_to_process[-1], $start_date, $end_date);
            $verify_transaction_mt5 = verify_transaction_mt5($accounts_to_process[-1], $start_date, $end_date);
        }

        try {
            $client = BOM::User::Client::get_instance({loginid => $deriv_account});
            my @linked_accounts = $client->user->loginids;
            my $linked_mt5      = grep { $_ eq 'MTR' . $mt5_account } @linked_accounts;
            push @errors, "MT5 account not found for the client" unless $linked_mt5;
        } catch {
            # If client is not found, it will go to catch
        }

        push @errors, "Transaction already processed" if $verify_transaction_mt5 == 1;
        push @errors, "Transaction not found in database" unless $verify_transaction_db;
        push @errors, "Invalid loginid"                   unless $client && $client->user->email;
        push @errors, "Invalid currency code" if LandingCompany::Registry::get_currency_type($currency_code) eq "";

        if (scalar @errors > 0) {
            push @invalid_lines, qq[<a class="link" href="#ln$line_number">Invalid line $line_number</a> : ] . join(", ", @errors);
        }

        my %row = (
            line_number      => $line_number,
            deriv_account    => $deriv_account,
            mt5_account      => $mt5_account,
            transaction_id   => $transaction_id,
            transaction_time => $transaction_time,
            amount           => $amount,
            fee              => $fee,
            currency_code    => $currency_code,
            amount_in_usd    => $amount_in_usd,
            notes            => scalar @errors > 0 ? join(", ", @errors)         : "OK",
            style            => scalar @errors > 0 ? "background-color:#db0000;" : "na",
        );

        $client_account_table .= construct_row(%row);
        push(@added_transactions, $transaction_id);
    });

if (scalar @invalid_lines > 0) {
    $summary_table .= '<h3>Error(s) found, please correct the line(s) below</h3>' . '<table>' . '<tr><th>Error</th></tr>';

    foreach my $invalid_line (@invalid_lines) {
        $summary_table .= '<tr><td>' . $invalid_line . '</td></tr>';
    }
    $summary_table .= '</table>';
}

if ($preview and @invalid_lines == 0) {
    print "<div style='text-align:center;'>
        <form method=post action='" . request()->url_for('backoffice/mt5_bulk_deposit.cgi') . "'>
            <input type=hidden name=accounts_to_process value='" . encode_json_utf8(\@accounts_to_process) . "'>
            <button type=submit class='btn btn--primary' name=confirm value=confirm>Deposit in bulk</button>
        </form>
        </div>";
}

print $summary_table;
print "<hr>";
print $client_account_table;

sub read_csv_row {
    my $csv_lines = shift;
    my $callback  = shift;

    foreach my $line (@{$csv_lines}) {
        chomp $line;
        my (@row_values) = split ',', $line;

        &$callback(@row_values);
    }
    return;
}

sub construct_row {
    my %args = @_;

    my $column_style = $args{style} && $args{style} ne "na" ? "color:white" : "color:black";

    return qq[ <tr style="$args{style}">
        <td><a name="ln$args{line_number}" style="$column_style">$args{line_number}</a></td>
        <td style="$column_style">$args{deriv_account}</td>
        <td style="$column_style">$args{mt5_account}</td>
        <td style="$column_style">$args{transaction_id}</td>
        <td style="$column_style">$args{transaction_time}</td>
        <td style="$column_style">$args{amount}</td>
        <td style="$column_style">$args{fee}</td>
        <td style="$column_style">$args{currency_code}</td>
        <td style="$column_style">$args{amount_in_usd}</td>
        <td style="$column_style">$args{notes}</td>
    </tr>];
}

sub get_mt5_group {
    my $account = shift;
    my $cfg     = LoadFile($config);

    foreach my $server (values $cfg->{real}->%*) {
        if ($server->{accounts}[0]->{from} <= $account && $server->{accounts}[0]->{to} >= $account) {
            return $server->{group_suffix};
        }
    }

    return undef;
}

sub get_past_exchange_rate {
    my $details = shift;

    my ($broker_code) = $details->{deriv_account} =~ /([A-Za-z]+)/g;

    my $clientdb = BOM::Database::ClientDB->new({broker_code => $broker_code})->db->dbic;

    my $result = $clientdb->run(
        fixup => sub {
            $_->selectrow_array(
                qq{ SELECT * FROM data_collection.exchangetousd(?, ?, ?)},
                {},
                $details->{amount} - $details->{fee},
                $details->{currency_code},
                $details->{transaction_time},
            );
        });

    return $result;
}

sub verify_transaction_mt5 {
    my ($details, $start_date, $end_date) = @_;

    return undef unless $details->{user_group};

    my $start_date_epoch = Date::Utility->new($start_date)->epoch;
    my $end_date_epoch   = Date::Utility->new($end_date)->epoch;

    my $mt5_transactions = http->post(
        "$mt5_proxy_url/real_$details->{user_group}/DealGetBatch",
        {
            content => encode_json_utf8({
                    login => $details->{mt5_account},
                    from  => $start_date_epoch,
                    to    => $end_date_epoch,
                }
            ),
            headers => {
                'Content-Type' => 'application/json',
                'Accept'       => 'application/json',
            }});

    my $mt5_deals = decode_json_utf8($mt5_transactions->{content})->{deal_get_batch};

    if (scalar @$mt5_deals > 0) {
        foreach (@$mt5_deals) {
            return 1 if $_->{comment} =~ m/$details->{transaction_id}/;
        }
    }

    return 0;
}

sub verify_transaction_db {
    my ($details, $start_date, $end_date) = @_;

    my ($broker_code) = $details->{deriv_account} =~ /([A-Za-z]+)/g;

    my $clientdb = BOM::Database::ClientDB->new({broker_code => $broker_code})->db->dbic;

    my $result = $clientdb->run(
        fixup => sub {
            $_->selectrow_array(
                qq{ SELECT * FROM transaction.verify_transaction(?, ?, ?, ?, ?, ?, ?, ?, ?)},
                {},
                $details->{transaction_id},
                $start_date,
                $end_date,
                -$details->{amount},
                $details->{deriv_account},
                'MTR' . $details->{mt5_account},
                'withdrawal',    # Money going from CR to MT5 is recorded as withdrawal
                $details->{fee},
                $details->{currency_code},
            );
        });

    return $result;
}

code_exit_BO();
