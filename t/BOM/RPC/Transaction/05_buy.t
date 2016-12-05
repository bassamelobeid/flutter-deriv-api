#!perl

use strict;
use warnings;

use utf8;
use Test::Most;
use Test::Mojo;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Database::Model::OAuth;

use BOM::Test::RPC::Client;
use Test::BOM::RPC::Contract;

my $email  = 'test@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
my $loginid = $client->loginid;

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]});

$client->deposit_virtual_funds;
my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
subtest 'buy' => sub {
    my $params = {
        language => 'EN',
        token    => 'invalid token'
    };
    $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'invalid token')
        ->error_message_is('The token is invalid.', 'invalid token');

    $params->{token} = $token;

    #I don't know how to set such a scenario that a valid token id has no valid client,
    #So I mock client module to simulate this scenario.
    my $mocked_client = Test::MockModule->new('Client::Account');
    $mocked_client->mock('new', sub { return undef });
    $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('AuthorizationRequired', 'AuthorizationRequired')
        ->error_message_is('Please log in.', 'please login');
    undef $mocked_client;

    $params->{contract_parameters} = {};
    {
        local $SIG{'__WARN__'} = sub {
            my $msg = shift;
            if ($msg !~ /Use of uninitialized value in pattern match/) {
                print STDERR $msg;
            }
        };
        $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('ContractCreationFailure', 'ContractCreationFailure')
            ->error_message_is('Cannot create contract', 'cannot create contract');

    }

    my $contract = Test::BOM::RPC::Contract::create_contract();

    $params->{source}              = 1;
    $params->{contract_parameters} = {
        "proposal"      => 1,
        "amount"        => "100",
        "basis"         => "payout",
        "contract_type" => "CALL",
        "currency"      => "USD",
        "duration"      => "120",
        "duration_unit" => "s",
        "symbol"        => "R_50",
    };
    my $result = $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('PriceMoved', 'price moved error')->result;
    like($result->{error}{message_to_client}, qr/The underlying market has moved too much since you priced the contract./, 'price moved error');

    $params->{args}{price} = $contract->ask_price;
    my $old_balance = $client->default_account->load->balance;
    $result = $c->call_ok('buy', $params)->has_no_system_error->has_no_error->result;
    my @expected_keys = (qw(
            transaction_id
            contract_id
            balance_after
            purchase_time
            buy_price
            start_time
            longcode
            shortcode
            payout
            stash
    ));
    is_deeply([sort keys %$result], [sort @expected_keys], 'result keys is ok');
    my $new_balance = sprintf('%.2f', $client->default_account->load->balance);
    is($new_balance, $result->{balance_after}, 'balance is changed');
    ok($old_balance - $new_balance - $result->{buy_price} < 0.0001, 'balance reduced');
    like($result->{shortcode}, qr/CALL_R_50_100_\d{10}_\d{10}_S0P_0/, 'shortcode is correct');
    is(
        $result->{longcode},
        'Win payout if Volatility 50 Index is strictly higher than entry spot at 2 minutes after contract start time.',
        'longcode is correct'
    );

    #Try setting trading period start in parameters.
    $params->{contract_parameters}{trading_period_start} = time - 3600;
    $result = $c->call_ok('buy', $params)->has_no_system_error->has_no_error->result;

    $contract = Test::BOM::RPC::Contract::create_contract(is_spread => 1);
    $params->{contract_parameters} = {
        "proposal"         => 1,
        "amount"           => "100",
        "basis"            => "payout",
        "contract_type"    => "SPREADU",
        "currency"         => "USD",
        "stop_profit"      => "10",
        "stop_type"        => "point",
        "amount_per_point" => "1",
        "stop_loss"        => "10",
        "symbol"           => "R_50",
    };

    $params->{args}{price} = $contract->ask_price;

    $result = $c->call_ok('buy', $params)->has_no_system_error->has_no_error->result;
    push @expected_keys, qw(stop_loss_level stop_profit_level amount_per_point);
    is_deeply([sort keys %$result], [sort @expected_keys], 'result spread keys is ok');

};

subtest 'app_markup' => sub {
    my $contract = Test::BOM::RPC::Contract::create_contract();

    my $params = {
        language            => 'EN',
        token               => $token,
        source              => 1,
        contract_parameters => {
            "proposal"      => 1,
            "amount"        => "100",
            "basis"         => "payout",
            "contract_type" => "CALL",
            "currency"      => "USD",
            "duration"      => "120",
            "duration_unit" => "s",
            "symbol"        => "R_50",
        },
        args => {price => $contract->ask_price}};
    my $payout    = $contract->payout;
    my $ask_price = $contract->ask_price;

    my $result = $c->call_ok('buy', $params)->has_no_system_error->has_no_error->result;
    my @expected_keys = (qw(
            transaction_id
            contract_id
            balance_after
            purchase_time
            buy_price
            start_time
            longcode
            shortcode
            payout
            stash
    ));
    is_deeply([sort keys %$result], [sort @expected_keys], 'result keys is ok');
    is $payout, $result->{payout}, "contract and transaction payout are equal";
    is $result->{buy_price}, $ask_price, "ideally contract ask_price is same as buy_price";

    delete $params->{args}->{price};

    $contract = Test::BOM::RPC::Contract::create_contract(app_markup_percentage => 1);
    $params->{contract_parameters}->{app_markup_percentage} = 1;

    $params->{args}->{price} = $contract->ask_price;
    $result = $c->call_ok('buy', $params)->has_no_system_error->has_no_error->result;
    is $result->{buy_price}, $ask_price + 1, "buy_price is ask_price plus + app_markup same for payout";

    # check for stake contracts
    $contract = Test::BOM::RPC::Contract::create_contract(basis => 'stake');
    $payout = $contract->payout;

    $contract = Test::BOM::RPC::Contract::create_contract(
        basis                 => 'stake',
        app_markup_percentage => 1
    );
    $params->{contract_parameters}->{basis}                 = "stake";
    $params->{contract_parameters}->{app_markup_percentage} = 1;

    $params->{args}->{price} = $contract->ask_price;
    $result = $c->call_ok('buy', $params)->has_no_system_error->has_no_error->result;
    cmp_ok $payout, ">", $result->{payout}, "Payout in case of stake contracts that have app_markup will be less than original payout";
};

subtest 'app_markup_transaction' => sub {
    my $contract = Test::BOM::RPC::Contract::create_contract();

    my $now = time - 180;
    my $txn = BOM::Product::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        purchase_date => $now,
        amount_type   => 'payout',
    });
    is $txn->buy(skip_validation => 1), undef, "no error in transaction buy";
    is $txn->app_markup, 0, "no app markup";

    my $app_markup_percentage = 1;
    $contract = Test::BOM::RPC::Contract::create_contract(app_markup_percentage => $app_markup_percentage);
    $now      = time - 120;
    $txn      = BOM::Product::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        purchase_date => $now,
        amount_type   => 'payout',
    });
    is $txn->buy(skip_validation => 1), undef, "no error in transaction buy";
    is $txn->app_markup, $app_markup_percentage / 100 * $contract->payout,
        "transaction app_markup is app_markup_percentage of contract payout for payout amount_type";

    $contract = Test::BOM::RPC::Contract::create_contract(basis => 'stake');
    my $payout = $contract->payout;
    $now = time - 60;
    $txn = BOM::Product::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        purchase_date => $now,
        amount_type   => 'payout',
    });
    is $txn->buy(skip_validation => 1), undef, "no error in transaction buy for stake";
    is $txn->app_markup, 0, "no app markup for stake";

    $app_markup_percentage = 2;
    $contract              = Test::BOM::RPC::Contract::create_contract(
        basis                 => 'stake',
        app_markup_percentage => $app_markup_percentage
    );
    $now = time;
    $txn = BOM::Product::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        purchase_date => $now,
        amount_type   => 'payout',
    });
    is $txn->buy(skip_validation => 1), undef, "no error in transaction buy for stake";
    is $txn->app_markup, sprintf('%.2f', $txn->payout * $app_markup_percentage / 100),
        "in case of stake contract, app_markup is app_markup_percentage of final payout i.e transaction payout";
    cmp_ok $txn->payout, "<", $payout, "payout after app_markup_percentage is less than actual payout";

    $contract = Test::BOM::RPC::Contract::create_contract(
        is_spread             => 1,
        app_markup_percentage => $app_markup_percentage
    );
    $now = time;
    $txn = BOM::Product::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        purchase_date => $now,
        amount_type   => 'payout',
    });
    is $txn->app_markup, 0, "no app markup for spread contracts as of now, may be added in future";
};

done_testing();
