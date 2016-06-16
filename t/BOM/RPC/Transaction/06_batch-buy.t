#!perl

use strict;
use warnings;

use Test::More;
use BOM::RPC::v3::Transaction;
use BOM::RPC::v3::Accounts;
use BOM::RPC::v3::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::Product;

{
    use BOM::Database::Model::AccessToken;

    # cleanup
    BOM::Database::Model::AccessToken->new->dbh->do('DELETE FROM auth.access_token');
}

my $clm = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => 'test-manager@binary.com',
});
$clm->set_default_account('USD'); # the manager needs an account record but no money.
$clm->save;

my $clm_token = BOM::RPC::v3::Accounts::api_token({
    client => $clm,
    args   => {
        new_token        => 'Test Token',
        new_token_scopes => ['trade'],
    },
})->{tokens}->[0]->{token};

my $clm_token_details = BOM::RPC::v3::Utility::get_token_details($clm_token);

my @cl;
push @cl, BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => 'test-cl0@binary.com',
});
$cl[-1]->deposit_virtual_funds;

push @cl, BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => 'test-cl1@binary.com',
});
$cl[-1]->deposit_virtual_funds;

push @cl, BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => 'test-cl2@binary.com',
});
# no funding here ==> error

my @token;
for (@cl) {
    my $t = BOM::RPC::v3::Accounts::api_token({
        client => $_,
        args   => {
            new_token        => 'Test Token',
            new_token_scopes => ['trade'],
        },
    })->{tokens}->[0]->{token};
    push @token, $t if $t;
}
is 0+@token, 3, 'got 3 tokens';

note explain \@token;

my $contract = BOM::Test::Data::Utility::Product::create_contract();

my $result=BOM::RPC::v3::Transaction::buy_contract_for_multiple_accounts {
    token_details => $clm_token_details,
    tokens => \@token,
    source => 1,
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
    args => {price => $contract->ask_price},
};

is_deeply \@token, [map {$_->{token}} @$result], 'result is in order';

for my $k (qw/contract_id transaction_id/) {
    isnt $result->[0]->{$k}, undef, "got 1st $k";
    isnt $result->[1]->{$k}, undef, "got 2nd $k";
    isnt $result->[0]->{$k}, $result->[1]->{$k}, 'and they differ';
}

for my $k (qw/purchase_time buy_price start_time longcode shortcode payout/) {
    isnt $result->[0]->{$k}, undef, "got 1st $k";
    isnt $result->[1]->{$k}, undef, "got 2nd $k";
    is $result->[0]->{$k}, $result->[1]->{$k}, 'and they equal';
}



note explain $result;

done_testing;

__END__


use utf8;
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::Product;

my $email  = 'test@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
my $loginid = $client->loginid;

my $token = BOM::Platform::SessionCookie->new(
    loginid => $loginid,
    email   => $email
)->token;

$client->
my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
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
    my $mocked_client = Test::MockModule->new('BOM::Platform::Client');
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

    my $contract = BOM::Test::Data::Utility::Product::create_contract();

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
    ));
    is_deeply([sort keys %$result], [sort @expected_keys], 'result keys is ok');
    my $new_balance = $client->default_account->load->balance;
    is($new_balance, $result->{balance_after}, 'balance is changed');
    ok($old_balance - $new_balance - $result->{buy_price} < 0.0001, 'balance reduced');
    like($result->{shortcode}, qr/CALL_R_50_100_\d{10}_\d{10}_S0P_0/, 'shortcode is correct');
    is(
        $result->{longcode},
        'Win payout if Volatility 50 Index is strictly higher than entry spot at 2 minutes after contract start time.',
        'longcode is correct'
    );

    $contract = BOM::Test::Data::Utility::Product::create_contract(is_spread => 1);
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

done_testing();
