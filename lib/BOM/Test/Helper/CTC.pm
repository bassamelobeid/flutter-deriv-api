package BOM::Test::Helper::CTC;

use strict;
use warnings;

use Exporter qw( import );
use BOM::CTC::Helper;
use BOM::CTC::Currency;
use BOM::Platform::Client::CashierValidation;

our @EXPORT_OK = qw( wait_miner );

BEGIN {
    *BOM::Platform::Client::CashierValidation::is_crypto_currency_suspended = sub {
        return 0;
    };
}

=head2 wait_miner

Wait until a transaction is mined into a block.

This is a workaround until we can run tests asynchronously in bom-cryptocurrency.

=cut

sub wait_miner {
    my ($currency_code, $txhash) = @_;
    return undef unless $txhash;

    my $currency = BOM::CTC::Currency->new(currency_code => $currency_code);

    my $transaction;
    do {
        sleep 1;
        $transaction = $currency->rpc_client()->eth_getTransactionByHash($txhash);
    } until defined $transaction->{blockNumber};

    return undef;
}

sub deploy_test_contract {
    my ($currency_code, $bytecode) = @_;

    my $currency = BOM::CTC::Currency->new(currency_code => $currency_code);

    $bytecode =~ s/[\x0D\x0A]+//g;

    # 0 here means that we will unlock this account until geth be restarted
    $currency->rpc_client->personal_unlockAccount($currency->account_config->{account}->{address}, $currency->account_config->{account}->{passphrase}, 0);

    my $total_supply = Math::BigFloat->new(1000)->bmul(Math::BigInt->new(10)->bpow(18))->numify;
    $currency->_contract->gas(4_000_000);
    # the number 35 here is the time in seconds that we will wait to the contract be
    # deployed, for the tests since we are using a private node this works fine, this
    # will be removed on the future when we make the ethereum client async.
    my $response = $currency->_contract->invoke_deploy($bytecode, "Binary.com", "", $total_supply, $currency->account_config->{account}->{address})
        ->get_contract_address(35);

    $currency->_contract->contract_address($response->get->response);

    # here we need to set the contract address into Redis, since
    # we will use this contract in the tests
    $currency->set_contract_address($currency->_contract->contract_address);

    return $currency->_contract->contract_address;
}


1;
