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
use Log::Any qw($log);
use LandingCompany::Registry;

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("Crypto Wrong Currency Deposit");

my @all_cryptos      = LandingCompany::Registry::all_crypto_currencies();
my $transaction_hash = trim(request()->param('transaction_hash'));
my $to_address       = trim(request()->param('to_address'));
my $currency_code    = request()->param('currency');
my $broker           = request()->broker_code;
my $clientdb         = BOM::Database::ClientDB->new({broker_code => $broker});
my $response_bodies;
my $sibling_account;
my $status;

my $batch = BOM::Cryptocurrency::BatchAPI->new();

if ($transaction_hash) {

    $batch->add_request(
        id     => 'check_wrong_currency_deposit',
        action => 'deposit/check_wrong_currency_deposit',
        body   => {
            transaction_hash => $transaction_hash,
            to_address       => $to_address,
            currency_code    => $currency_code,
        },
    );

    $batch->process();
    $response_bodies = $batch->get_response_body('check_wrong_currency_deposit');

    if (%$response_bodies) {
        my $wrong_currency_code   = $response_bodies->{wrong_currency};
        my $correct_currency_code = $response_bodies->{correct_currency};
        my $client_loginid        = $response_bodies->{client_loginid};
        $status          = $response_bodies->{status};
        $sibling_account = $response_bodies->{sibling_client_loginid};
        # Check if sibling account has been created in the database
        $sibling_account = get_sibiling_account_by_currency_code($client_loginid, $wrong_currency_code) if $status eq 'ERROR';
    }
}

BOM::Backoffice::Request::template()->process(
    'backoffice/crypto_wrong_currency_deposit.html.tt',
    {
        data_url          => request()->url_for('backoffice/crypto_wrong_currency_deposit.cgi'),
        data              => $response_bodies,
        transaction_hash  => $transaction_hash,
        to_address        => $to_address,
        sibling_account   => $sibling_account,
        currency_options  => \@all_cryptos,
        currency_selected => $currency_code,
        status            => $status,
        credit_url        => request()->url_for('backoffice/crypto_credit_wrong_currency_deposits.cgi'),
    }) || die BOM::Backoffice::Request::template()->error(), "\n";

code_exit_BO();
