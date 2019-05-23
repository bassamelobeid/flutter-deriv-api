#!perl

use strict;
use warnings;

use utf8;
use Test::Most;
use Test::Mojo;
use Test::MockModule;

use Format::Util::Numbers qw/formatnumber/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Database::Model::OAuth;

use BOM::Test::RPC::Client;
use Test::BOM::RPC::Contract;
use Email::Stuffer::TestLinks;

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
my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);
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
    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    $mocked_client->mock('new', sub { return undef });
    $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('AuthorizationRequired', 'AuthorizationRequired')
        ->error_message_is('Please log in.', 'please login');
    undef $mocked_client;

    $params->{contract_parameters} = {};
    {
        local $SIG{'__WARN__'} = sub {
            my $msg = shift;
            if ($msg !~ /Use of uninitialized value \$_ in pattern match/) {
                print STDERR $msg;
            }
        };
        $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('ContractCreationFailure', 'ContractCreationFailure')
            ->error_message_is('Missing required contract parameters (bet_type).', 'Missing required contract parameters (bet_type).');
    }

    my (undef, $txn_con) = Test::BOM::RPC::Contract::prepare_contract(client => $client);

    $params->{source}              = 1;
    $params->{contract_parameters} = {
        "proposal"      => 1,
        "amount"        => "100",
        "basis"         => "payout",
        "contract_type" => "ONETOUCH",
        "currency"      => "USD",
        "duration"      => "5",
        "duration_unit" => "t",
        "symbol"        => "R_50",
        "barrier"       => "+0.5",
    };

    my $result = $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('PriceMoved', 'price moved error')->result;
    like($result->{error}{message_to_client}, qr/The underlying market has moved too much since you priced the contract./, 'price moved error');

    $params->{args}{price} = $txn_con->contract->ask_price;

    $params->{contract_parameters}{barrier} = "+0.555555555";

    $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('BarrierValidationError', 'BarrierValidationError')
        ->error_message_is('Barrier can only be up to 4 decimal places.', 'Barrier can only be up to 4 decimal places.');

    delete $params->{contract_parameters}{barrier};

    $params->{contract_parameters}{barrier} = "+0.5";

    my $old_balance = $client->default_account->balance;
    $result = $c->call_ok('buy', $params)->has_no_system_error->has_no_error->result;
    my @expected_keys = (qw(
            transaction_id
            contract_id
            contract_details
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
    my $new_balance = formatnumber('amount', 'USD', $client->default_account->balance);
    is($new_balance, $result->{balance_after}, 'balance is changed');
    ok($old_balance - $new_balance - $result->{buy_price} < 0.0001, 'balance reduced');
    like($result->{shortcode}, qr/ONETOUCH_R_50_100_\d{10}_/, 'shortcode is correct');
    is(
        $result->{longcode},
        'Win payout if Volatility 50 Index touches entry spot plus 0.5000 through 5 ticks after first tick.',
        'longcode is correct'
    );

    #Try setting trading period start in parameters.
    $params->{contract_parameters}{trading_period_start} = time - 3600;
    $result = $c->call_ok('buy', $params)->has_no_system_error->has_no_error->result;

    $params->{contract_parameters} = {
        "proposal"      => 1,
        "amount"        => "0.95",
        "basis"         => "stake",
        "contract_type" => "ONETOUCH",
        "currency"      => "USD",
        "duration"      => "5",
        "duration_unit" => "t",
        "symbol"        => "R_50",
        "ask-price"     => "0.95",
        "payout"        => "1.84",
        "barrier"       => "+0.5",
    };

    $params->{contract_parameters}->{amount} = "0.956";
    $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('InvalidAmount', 'Invalid precision for amount');

    $params->{contract_parameters}->{amount} = "0.95";
    $params->{args}{price} = "0.956";
    $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('InvalidPrice', 'Invalid precision for price');

    $params->{args}{price} = "0.95";
    delete $params->{contract_parameters}->{payout};
    $result = $c->call_ok('buy', $params)->has_no_system_error->has_no_error->result;
    ok $result->{contract_id},    'buy response has contract id';
    ok $result->{transaction_id}, 'buy response has transaction id';
};

subtest 'app_markup' => sub {
    my (undef, $txn_con) = Test::BOM::RPC::Contract::prepare_contract(client => $client);

    my $params = {
        language            => 'EN',
        token               => $token,
        source              => 1,
        contract_parameters => {
            "proposal"      => 1,
            "amount"        => "100",
            "basis"         => "payout",
            "contract_type" => "ONETOUCH",
            "currency"      => "USD",
            "duration"      => "5",
            "duration_unit" => "t",
            "symbol"        => "R_50",
            "barrier"       => "+0.5",
        },
        args => {price => 7.04}};
    my $payout    = $txn_con->contract->payout;
    my $ask_price = 7.04;

    my $result = $c->call_ok('buy', $params)->has_no_system_error->has_no_error->result;
    my @expected_keys = (qw(
            transaction_id
            contract_id
            contract_details
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

    (undef, $txn_con) = Test::BOM::RPC::Contract::prepare_contract(
        client                => $client,
        app_markup_percentage => 1
    );
    $params->{contract_parameters}->{app_markup_percentage} = 1;

    $params->{args}->{price} = 8.04;
    $result = $c->call_ok('buy', $params)->has_no_system_error->has_no_error->result;
    is $result->{buy_price}, $ask_price + 1, "buy_price is ask_price plus + app_markup same for payout";

    # check for stake contracts
    (undef, $txn_con) = Test::BOM::RPC::Contract::prepare_contract(
        client => $client,
        basis  => 'stake'
    );

    $payout = $txn_con->contract->payout;

    (undef, $txn_con) = Test::BOM::RPC::Contract::prepare_contract(
        client                => $client,
        basis                 => 'stake',
        app_markup_percentage => 1
    );
    $params->{contract_parameters}->{basis}                 = "stake";
    $params->{contract_parameters}->{app_markup_percentage} = 1;

    $params->{args}->{price} = $txn_con->contract->ask_price;
    $result = $c->call_ok('buy', $params)->has_no_system_error->has_no_error->result;

};

subtest 'app_markup_transaction' => sub {
    my ($contract_details, $txn_con) = Test::BOM::RPC::Contract::prepare_contract(client => $client);

    my $now = time - 180;
    my $txn = BOM::Transaction->new({
        client              => $client,
        contract_parameters => $contract_details,
        price               => $txn_con->contract->ask_price,
        purchase_date       => $now,
        amount_type         => 'payout',
    });
    is $txn->buy(skip_validation => 1), undef, "no error in transaction buy";
    cmp_ok $txn->contract->app_markup_dollar_amount(), '==', 0, "no app markup";

    my $app_markup_percentage = 1;
    ($contract_details, $txn_con) = Test::BOM::RPC::Contract::prepare_contract(
        client                => $client,
        app_markup_percentage => $app_markup_percentage
    );

    $now = time - 120;
    $txn = BOM::Transaction->new({
        client              => $client,
        contract_parameters => $contract_details,
        price               => $txn_con->contract->ask_price,
        purchase_date       => $now,
        amount_type         => 'payout',
    });
    is $txn->buy(skip_validation => 1), undef, "no error in transaction buy";
    cmp_ok $txn->contract->app_markup_dollar_amount(), '==', $app_markup_percentage / 100 * $txn_con->contract->payout,
        "transaction app_markup is app_markup_percentage of contract payout for payout amount_type";

    ($contract_details, $txn_con) = Test::BOM::RPC::Contract::prepare_contract(
        client => $client,
        basis  => 'stake'
    );

    my $payout = $txn_con->contract->payout;
    $now = time - 60;
    $txn = BOM::Transaction->new({
        client              => $client,
        contract_parameters => $contract_details,
        price               => $txn_con->contract->ask_price,
        purchase_date       => $now,
        amount_type         => 'payout',
    });
    is $txn->buy(skip_validation => 1), undef, "no error in transaction buy for stake";
    cmp_ok $txn->contract->app_markup_dollar_amount(), '==', 0, "no app markup for stake";

    $app_markup_percentage = 2;
    ($contract_details, $txn_con) = Test::BOM::RPC::Contract::prepare_contract(
        client                => $client,
        basis                 => 'stake',
        app_markup_percentage => $app_markup_percentage
    );
    $now = time;
    $txn = BOM::Transaction->new({
        client              => $client,
        contract_parameters => $contract_details,
        price               => $txn_con->contract->ask_price,
        purchase_date       => $now,
        amount_type         => 'payout',
    });
    is $txn->buy(skip_validation => 1), undef, "no error in transaction buy for stake";
    is $txn->contract->app_markup_dollar_amount(), formatnumber('amount', 'USD', $txn->payout * $app_markup_percentage / 100),
        "in case of stake contract, app_markup is app_markup_percentage of final payout i.e transaction payout";
    cmp_ok $txn->payout, "<", $payout, "payout after app_markup_percentage is less than actual payout";
};

done_testing();
