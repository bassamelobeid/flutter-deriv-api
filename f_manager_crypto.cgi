#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use HTML::Entities;

use Bitcoin::RPC::Client;
use Data::Dumper;
use YAML::XS;
use Client::Account;
use Text::CSV;
use List::UtilsBy qw(rev_nsort_by);

use BOM::Database::ClientDB;
use BOM::Backoffice::PlackHelpers qw/PrintContentType_excel PrintContentType/;
use f_brokerincludeall;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

my $broker         = request()->broker_code;
my $encoded_broker = encode_entities($broker);
my $staff          = BOM::Backoffice::Auth0::can_access(['Payments']);
my $currency       = request()->param('currency');
my $action         = request()->param('action');
my $address        = request()->param('address');
my $view_type      = request()->param('view_type') // 'pending';

if (length($broker) < 2) {
    PrintContentType();
    BrokerPresentation('CRYPTO CASHIER MANAGEMENT');
    print
        "We cannot process your request because it would seem that your browser is not configured to accept cookies.  Please check that the 'enable cookies' function is set if your browser, then please try again.";
    code_exit_BO();
}

if (not $currency or $currency !~ /^[A-Z]{3}$/) {
    PrintContentType();
    BrokerPresentation('CRYPTO CASHIER MANAGEMENT');
    print "Invalid currency.";
    code_exit_BO();
}

my $page = request()->param('view_action') // '';
my $clientdb = BOM::Database::ClientDB->new({broker_code => $encoded_broker});
my $dbh = $clientdb->db->dbh;

if ($page eq 'Transactions') {
    PrintContentType();
    BrokerPresentation('CRYPTO CASHIER MANAGEMENT');
    if ($address and $address !~ /^\w+$/) {
        print "Invalid address.";
        code_exit_BO();
    }

    if ($action and $action !~ /^[a-zA-Z]{4,15}$/) {
        print "Invalid action.";
        code_exit_BO();
    }

    if (not $view_type or $view_type !~ /^(?:pending|verified|rejected|sent|error)$/) {
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

    my $trxns;
    if ($view_type eq 'sent') {
        $trxns = $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(?, 'SENT'::payment.CTC_STATUS, NULL, NULL)",
            {Slice => {}}, $currency);
    } elsif ($view_type eq 'verified') {
        $trxns = $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(?, 'VERIFIED'::payment.CTC_STATUS, NULL, NULL)",
            {Slice => {}}, $currency);
    } elsif ($view_type eq 'rejected') {
        $trxns = $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(?, 'REJECTED'::payment.CTC_STATUS, NULL, NULL)",
            {Slice => {}}, $currency);
    } elsif ($view_type eq 'error') {
        $trxns = $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(?, 'ERROR'::payment.CTC_STATUS, NULL, NULL)",
            {Slice => {}}, $currency);
    } else {
        $trxns = $dbh->selectall_arrayref("SELECT * FROM payment.ctc_bo_get_withdrawal(?, 'LOCKED'::payment.CTC_STATUS, NULL, NULL)",
            {Slice => {}}, $currency);
    }

    Bar("LIST OF TRANSACTIONS - WITHDRAWAL");

    my $tt = BOM::Backoffice::Request::template;
    $tt->process(
        'backoffice/account/manage_crypto_transactions.tt',
        {
            transactions => $trxns,
            broker       => $broker,
            view_type    => $view_type,
            currency     => $currency,
        }) || die $tt->error();

} elsif ($page eq 'Deposit Transactions') {
    PrintContentType();
    BrokerPresentation('CRYPTO CASHIER MANAGEMENT');

    $view_type ||= 'new';
    if (not $view_type or $view_type !~ /^(?:new|pending|confirmed|error)$/) {
        print "Invalid selection to view type of transactions.";
        code_exit_BO();
    }

    my $trxns = $dbh->selectall_arrayref(
        "SELECT * FROM payment.ctc_bo_get_deposit(?, ?::payment.CTC_STATUS, NULL, NULL)",
        {Slice => {}},
        $currency, uc $view_type
    );

    Bar("LIST OF TRANSACTIONS - DEPOSITS");

    my $tt = BOM::Backoffice::Request::template;
    $tt->process(
        'backoffice/account/manage_crypto_transactions.tt',
        {
            transactions     => $trxns,
            broker           => $broker,
            transaction_type => 'deposit',
            view_type        => $view_type,
            currency         => $currency,
        }) || die $tt->error();

} elsif ($page eq 'Balances') {
    PrintContentType_excel($currency . '.csv');

    # Things required for this to work:
    # Access to bitcoin/litecoin/eth servers
    # Credentials for RPC
    # Client::Account
    # List addresses RPC call
    # Crypto database for address => login_id mapping

    my $rpc_client =
        $currency eq 'BTC' ? Bitcoin::RPC::Client->new(((), timeout => 10)) : die 'unsupported currency ' . $currency;
    my $csv      = Text::CSV->new;
    my @hdrs     = qw(address login_id transaction_date status reused amount currency_code);
    my $clientdb = BOM::Database::ClientDB->new({broker_code => 'CR'});
    my $sth      = $dbh->prepare(q{SELECT * FROM payment.ctc_find_login_id_for_address(?, ?)});

    # Track whether we have reused addresses
    my %seen;
    for my $transaction ($rpc_client->getaddresses) {
        my $address = $transaction->{address};
        my ($login_id) = @{$sth->fetchall_arrayref($currency, $address)} or die 'could not find login_id for address ' . $address;
        my %data = {
            address       => $address,
            login_id      => $login_id,
            amount        => $transaction->{amount},
            currency_code => $currency,
        };
        # $data{transaction_date} should be most recent transaction on the current address
        # $data{status} could be the most recent status from the crypto transactions table
        $data{reused} = 1 if $seen{$address}++;

        $csv->combine(@data{@hdrs});
        print $csv->string . "\n";
    }
} elsif ($page eq 'Run tool') {
    PrintContentType();
    my $cfg               = YAML::XS::LoadFile('/etc/rmg/cryptocurrency_rpc.yml');
    my $rpc_client        = Bitcoin::RPC::Client->new((%{$cfg->{bitcoin}}, timeout => 5));
    my $cmd               = request()->param('command');
    my %valid_rpc_command = (
        listaccounts         => 1,
        listtransactions     => 1,
        listaddressgroupings => 1,
    );
    if ($valid_rpc_command{$cmd}) {
        my $rslt = $rpc_client->$cmd;
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
                $_ = '<a href="https://www.blocktrail.com/tBTC/tx/' . $_ . '">' . $_ . '</a>' for $fields[1];
                print '<tr>';
                print '<td>' . $_ . '</td>' for @fields;
                print "</tr>\n";
            }
            print '</tbody></table>';
        } elsif ($cmd eq 'listaddressgroupings') {
            print '<table><thead><tr><th scope="col">Account</th><th scope="col">Address</th><th scope="col">Amount</th></tr></thead><tbody>';
            for my $item (@$rslt) {
                for my $address (@$item) {
                    print '<tr>';
                    # Reverse the order so we show the account in the first column
                    print '<td>' . encode_entities($_) . "</td>\n" for reverse @$address;
                    print "<tr>\n";
                }
            }
            print '</tbody></table>';
        } else {
            print encode_entities(Dumper $rslt);
        }
    } else {
        die 'Invalid BTC command: ' . $cmd;
    }
}
code_exit_BO();
