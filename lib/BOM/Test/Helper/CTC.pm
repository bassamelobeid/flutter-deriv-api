package BOM::Test::Helper::CTC;

use strict;
use warnings;

use Exporter qw( import );

use JSON::MaybeXS;
use Path::Tiny;
use Syntax::Keyword::Try;

use BOM::CTC::Config;
use BOM::CTC::Config::Cashier;
use BOM::CTC::Currency;
use BOM::CTC::Database;
use BOM::CTC::Daemon;

use BOM::Config::Redis;

our @EXPORT_OK =
    qw( wait_miner deploy_erc20_test_contract set_pending deploy_batch_withdrawal_test_contract top_up_eth_batch_withdrawal_contract create_loginid deploy_batch_balance_test_contract deploy_all_erc20_test_contracts populate_exchange_rates);

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
    my ($address, $currency_code, $amount, $transaction, $trace_id) = @_;

    $trace_id //= "trace_id_" . time . "_" . rand(1e9);

    my $dbic = BOM::CTC::Database->new()->dbic();
    # since we are using bom-events for subscription we need to set
    # the transaction to pending manually here.
    try {
        return $dbic->run(
            ping => sub {
                $_->selectrow_array('SELECT payment.ctc_set_deposit_pending(?, ?, ?, ?, ?)',
                    undef, $address, $currency_code, $amount, $transaction, $trace_id);
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
    for (BOM::CTC::Config::Cashier::all_crypto_currencies()) {
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

    my $constructor =
        '{ "inputs": [ { "internalType": "string", "name": "symbol", "type": "string" }, { "internalType": "string", "name": "name", "type": "string" }, { "internalType": "uint256", "name": "total_supply", "type": "uint256" }, { "internalType": "uint8", "name": "decimals", "type": "uint8" } ], "stateMutability": "nonpayable", "type": "constructor" }';

    my $decoded_abi = decode_json($currency->_minimal_erc20_abi);
    push(@$decoded_abi, decode_json($constructor));

    my $contract = $currency->rpc_client->contract({
        contract_abi => encode_json($decoded_abi),
        from         => $currency->account_config->{account}->{address},
        # The default contract gas is lower that what we need to deploy this contract
        # so we need manually specify the maximum amount of gas needed to deploy the
        # contract, this not means that we will use this entire gas, but the estimation
        # of the node generally it's bigger than what it will really use.
        # the number 4_000_000 we get from the tests, being enough to deploy this contract.
        gas => 4000000,
    });

    my $decimals = BOM::CTC::Config::crypto()->{$currency_code}->{decimal_places};

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

sub deploy_batch_withdrawal_test_contract {
    my $currency = BOM::CTC::Currency->new(currency_code => 'ETH');
    my $path     = "/home/git/regentmarkets/bom-test/resources/batch_withdrawal_bytecode";

    return undef unless -e $path;

    my $bytecode = path($path)->slurp();
    $bytecode =~ s/[\x0D\x0A]+//g;
    my $withdrawal_daemon = BOM::CTC::Daemon->new(
        daemon        => 'WithdrawalDaemon',
        currency_code => 'ETH',
    );
    my $decoded_abi = decode_json($withdrawal_daemon->_batch_withdrawal_abi);

    my $contract = $currency->rpc_client->contract({
        contract_abi => encode_json($decoded_abi),
        from         => $currency->account_config->{account}->{address},
        # The default contract gas is lower that what we need to deploy this contract
        # so we need manually specify the maximum amount of gas needed to deploy the
        # contract, this not means that we will use this entire gas, but the estimation
        # of the node generally it's bigger than what it will really use.
        # the number 4_000_000 we get from the tests, being enough to deploy this contract.
        gas => 4000000,
    });

    # 0 here means that we will unlock this account until geth be restarted
    $currency->rpc_client->personal_unlockAccount($currency->account_config->{account}->{address},
        $currency->account_config->{account}->{passphrase}, 0);

    # the number 35 here is the time in seconds that we will wait to the contract be
    # deployed, for the tests since we are using a private node this works fine, this
    # will be removed on the future when we make the ethereum client async.
    my $response = $contract->invoke_deploy($bytecode)->get_contract_address(35);
    $contract->contract_address($response->get->response);
    # here we need to set the contract address into Redis, since
    # we will use this contract in the tests
    $currency->set_batch_withdrawal_contract_address($contract->contract_address);

    return $contract->contract_address;
}

sub deploy_batch_balance_test_contract {
    my $currency = BOM::CTC::Currency->new(currency_code => 'ETH');
    my $path     = "/home/git/regentmarkets/bom-test/resources/batch_balance";

    my $bytecode = path($path . ".bytecode")->slurp();
    $bytecode =~ s/[\x0D\x0A]+//g;

    my $decoded_abi = path($path . ".abi")->slurp();

    my $contract = $currency->rpc_client->contract({
        contract_abi => $decoded_abi,
        from         => $currency->account_config->{account}->{address},
        # The default contract gas is lower that what we need to deploy this contract
        # so we need manually specify the maximum amount of gas needed to deploy the
        # contract, this not means that we will use this entire gas, but the estimation
        # of the node generally it's bigger than what it will really use.
        # the number 4_000_000 we get from the tests, being enough to deploy this contract.
        gas => 4000000,
    });

    # 0 here means that we will unlock this account until geth be restarted
    $currency->rpc_client->personal_unlockAccount($currency->account_config->{account}->{address},
        $currency->account_config->{account}->{passphrase}, 0);

    # the number 35 here is the time in seconds that we will wait to the contract be
    # deployed, for the tests since we are using a private node this works fine, this
    # will be removed on the future when we make the ethereum client async.
    my $response = $contract->invoke_deploy($bytecode)->get_contract_address(35);
    $contract->contract_address($response->get->response);

    return $contract->contract_address;
}

=head2 top_up_batch_withdrawal_contract

top-up batch withdrawal so that

=over

=item * C<address> - blockchain address

=item * C<currency_code> - currency code

=item * C<amount> - amount transacted

=item * C<transaction> - blockchain transaction hash

=back

=cut

sub top_up_eth_batch_withdrawal_contract {
    my ($amount) = @_;
    my $currency = BOM::CTC::Currency->new(currency_code => 'ETH');
    $currency->rpc_client->personal_unlockAccount($currency->account_config->{account}->{address},
        $currency->account_config->{account}->{passphrase}, 0);
    my $base_fee_calc = $currency->get_EIP1559_feecap();

    # Build transaction params
    my $params = {
        from                 => $currency->account_config->{account}->{address},
        to                   => $currency->get_batch_withdrawal_contract_address(),
        value                => $currency->get_blockchain_amount($amount)->as_hex(),
        maxFeePerGas         => $base_fee_calc->{max_fee}->as_hex(),
        maxPriorityFeePerGas => $base_fee_calc->{max_priority}->as_hex()};

    my $res = $currency->rpc_client->eth_sendTransaction([$params]);
    wait_miner($res);
    return undef;
}

=head2 create_loginid

Creates and returns a string of concatenating "id_" and an incremental counter.

=cut

my $loginid_counter = 1;

sub create_loginid {
    return "id_" . $loginid_counter++;
}

=head2 populate_exchange_rates

Populate the exchange rate in the Redis server for the crypto cashier currencies

=over

=item * C<local_rates> - A hashref of the currenices exchange rate (optional)

=back

=cut

my %all_currencies_rates = map { $_ => 1 } BOM::CTC::Config::Cashier::all_crypto_currencies();
my $rates                = \%all_currencies_rates;

sub populate_exchange_rates {
    my $local_rates = shift || $rates;
    $local_rates = {%$rates, %$local_rates};
    my $redis = BOM::Config::Redis::redis_exchangerates_write();
    $redis->hmset(
        'exchange_rates::' . $_ . '_USD',
        quote => $local_rates->{$_},
        epoch => time
    ) for keys %$local_rates;

    return;
}

1;
