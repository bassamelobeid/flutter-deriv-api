#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use HTML::Entities;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit      ();
use BOM::Cryptocurrency::BatchAPI;
use BOM::Database::ClientDB;
use Syntax::Keyword::Try;
use Log::Any                    qw($log);
use BOM::Cryptocurrency::Helper qw(has_manual_credit);

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("Crypto Wrong Currency Deposit");

my $transaction_hash = trim(request()->param('transaction_hash'));
my $to_address       = trim(request()->param('to_address'));
my $broker           = request()->broker_code;
my $clientdb         = BOM::Database::ClientDB->new({broker_code => $broker});
my $response_bodies;
my $sibiling_account;
my $has_manual_credit;

if ($transaction_hash) {
    my $batch = BOM::Cryptocurrency::BatchAPI->new();

    $batch->add_request(
        id     => 'check_wrong_currency_deposit',
        action => 'deposit/check_wrong_currency_deposit',
        body   => {
            transaction_hash => $transaction_hash,
            to_address       => $to_address,
        },
    );

    $batch->process();
    $response_bodies = $batch->get_response_body('check_wrong_currency_deposit');

    if (%$response_bodies) {
        my $wrong_currency_code = $response_bodies->{wrong_currency};
        my $client_loginid      = $response_bodies->{client_loginid};
        $sibiling_account  = get_sibiling_account_by_currency_code($client_loginid, $wrong_currency_code);
        $has_manual_credit = has_manual_credit($to_address, $wrong_currency_code, $broker) if ($sibiling_account);
    }

}

BOM::Backoffice::Request::template()->process(
    'backoffice/crypto_wrong_currency_deposit.html.tt',
    {
        data_url          => request()->url_for('backoffice/crypto_wrong_currency_deposit.cgi'),
        data              => $response_bodies,
        transaction_hash  => $transaction_hash,
        to_address        => $to_address,
        sibiling_account  => $sibiling_account,
        has_manual_credit => $has_manual_credit
    }) || die BOM::Backoffice::Request::template()->error(), "\n";

code_exit_BO();
