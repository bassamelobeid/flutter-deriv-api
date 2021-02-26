package BOM::Test::Helper::CTC;

use strict;
use warnings;

use Exporter qw( import );

use Test::MockModule;
use Path::Tiny;
use LandingCompany::Registry;

use BOM::CTC::Currency;
use BOM::Config::CurrencyConfig;
use BOM::CTC::Database;
use Syntax::Keyword::Try;

our @EXPORT_OK = qw( wait_miner deploy_erc20_test_contract set_pending );

my $mock_cashier_validation = Test::MockModule->new('BOM::Config::CurrencyConfig');
$mock_cashier_validation->mock(
    is_crypto_currency_suspended => sub {
        return 0;
    });

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

=head2 set_pending

set transaction as pending in payment.cryptocurrency

=over

=item * C<address> - blockchain address

=item * C<currency_code> - currency code

=item * C<amount> - amount transacted

=item * C<transaction> - blockchain transaction hash

=back

=cut

sub set_pending {
    my ($address, $currency_code, $amount, $transaction) = @_;

    my $dbic = BOM::CTC::Database->new()->cryptodb_dbic();
    # since we are using bom-events for subscription we need to set
    # the transaction to pending manually here.
    try {
        return $dbic->run(
            ping => sub {
                $_->selectrow_array('SELECT payment.ctc_set_deposit_pending(?, ?, ?, ?)', undef, $address, $currency_code, $amount, $transaction);
            });
    } catch {
        return 0;
    }
}

=head2 deploy_all_erc20_test_contracts

Generates test contract addresses for ERC20 currencies.
It returns a hash ref containing the addresses just created for ERC20 currencies.

=cut

sub deploy_all_erc20_test_contracts {
    my $result = {};
    for (LandingCompany::Registry->new()->all_crypto_currencies()) {
        my $contract_address = deploy_erc20_test_contract($_);
        $result->{$_} = $contract_address if $contract_address;
    }

    return $result;
}

sub deploy_erc20_test_contract {
    my ($currency_code) = @_;

    my $currency = BOM::CTC::Currency->new(currency_code => $currency_code);

    return undef unless ($currency->parent_currency // '') eq 'ETH';

    my $path = "/home/git/regentmarkets/bom-test/resources/erc20_bytecode";

    return undef unless -e $path;

    my $bytecode = path($path)->slurp();
    $bytecode =~ s/[\x0D\x0A]+//g;

    my $contract = $currency->rpc_client->contract({
        contract_abi => $currency->_minimal_erc20_abi,
        from         => $currency->account_config->{account}->{address},
        # The default contract gas is lower that what we need to deploy this contract
        # so we need manually specify the maximum amount of gas needed to deploy the
        # contract, this not means that we will use this entire gas, but the estimation
        # of the node generally it's bigger than what it will really use.
        # the number 4_000_000 we get from the tests, being enough to deploy this contract.
        gas => 4000000,
    });

    my $decimals = BOM::Config::crypto()->{$currency_code}->{decimal_places};

    # 0 here means that we will unlock this account until geth be restarted
    $currency->rpc_client->personal_unlockAccount($currency->account_config->{account}->{address},
        $currency->account_config->{account}->{passphrase}, 0);

    my $total_supply = Math::BigFloat->new(1000000000000)->bmul(Math::BigInt->new(10)->bpow($decimals))->numify();

    my $contract_currency_symbol = $currency_code eq 'eUSDT' ? 'USDT' : $currency_code;

    # the number 35 here is the time in seconds that we will wait to the contract be
    # deployed, for the tests since we are using a private node this works fine, this
    # will be removed on the future when we make the ethereum client async.
    my $response =
        $contract->invoke_deploy($bytecode, $contract_currency_symbol, $contract_currency_symbol, $total_supply, $decimals)->get_contract_address(35);

    $contract->contract_address($response->get->response);

    # here we need to set the contract address into Redis, since
    # we will use this contract in the tests
    $currency->set_contract_address($contract->contract_address);
    $currency->contract($contract);

    return $contract->contract_address;
}

1;
