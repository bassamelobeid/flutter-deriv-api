use strict;
use warnings;
use Test::More;
use Test::MockModule;

use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates);

use BOM::Database::Model::AccessToken;
use BOM::Config::RedisReplicated;
use BOM::User::Password;
use BOM::User;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use await;

my $t = build_wsapi_test({language => 'EN'});

#create client
my $email      = 'dummy' . rand(999) . '@binary.com';
my $client_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email,
    residence   => 'id',
});
$client_usd->set_default_account('USD');
my $user_client = BOM::User->create(
    email          => $email,
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
$user_client->add_client($client_usd);
my $client_token = BOM::Database::Model::AccessToken->new->create_token($client_usd->loginid, 'test token', ['read', 'payments']);

#Create payment agent
$email = 'dummy' . rand(999) . '@binary.com';
my $agent_name = 'Test Agent';
my $agent_usd  = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email,
    residence   => 'id',
});
$agent_usd->set_default_account('USD');
$agent_usd->payment_agent({
    payment_agent_name    => $agent_name,
    currency_code         => 'USD',
    url                   => 'http://www.example.com/',
    email                 => $email,
    phone                 => '+12345678',
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    is_authenticated      => 't',
    target_country        => 'id',
});
$agent_usd->save;

my $user_agent = BOM::User->create(
    email          => $email,
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
$user_agent->add_client($agent_usd);

my $agent_token = BOM::Database::Model::AccessToken->new->create_token($agent_usd->loginid, 'test token', ['read', 'payments']);

$client_usd->payment_free_gift(
    currency => 'USD',
    amount   => 1000,
    remark   => 'free gift',
);
$agent_usd->payment_free_gift(
    currency => 'USD',
    amount   => 1000,
    remark   => 'free gift',
);

subtest 'paymentagent_list' => sub {
    $t->await::authorize({authorize => $client_token});
    my $pa_list_response = $t->await::paymentagent_list({paymentagent_list => 'id'});

    is($pa_list_response->{error} // 0, 0, 'Successful payment agent list call');
    is($pa_list_response->{paymentagent_list}->{list}[0]->{paymentagent_loginid}, $agent_usd->loginid, 'Agent is included in the list');
    test_schema('paymentagent_list', $pa_list_response);

};

subtest 'paymentagent_transfer' => sub {
    $t->await::authorize({authorize => $agent_token});
    my $pa_balance = $agent_usd->default_account->balance;
    my $amount     = 10;
    my $client_id  = $client_usd->loginid;

    my $response = $t->await::paymentagent_transfer({
        paymentagent_transfer => 1,
        transfer_to           => $client_id,
        currency              => 'USD',
        amount                => $amount,
        description           => 'A message in a bottle'
    });

    is($response->{error} // 0, 0, 'Successful payment agent transfer');
    test_schema('paymentagent_transfer', $response);
    cmp_ok($pa_balance - $amount, '==', $agent_usd->default_account->balance, 'Payemnt agent balance is correct after transfer.');
    $pa_balance = $agent_usd->default_account->balance;

    check_last_statement($t, $agent_token, -$amount, 'withdrawal',
        qr/^Transfer from Payment Agent $agent_name to $client_id. Transaction reference: .* Timestamp: .* Agent note: A message in a bottle$/,
        $pa_balance, $response->{transaction_id});
    check_last_statement(
        $t, $client_token, $amount, 'deposit',
        qr/^Transfer from Payment Agent $agent_name to $client_id. Transaction reference: .* Timestamp: .* Agent note: A message in a bottle$/,
        $client_usd->default_account->balance
    );
};

subtest 'paymentagent_withdraw' => sub {
    $t->await::authorize({authorize => $client_token});
    my $client_balance = $client_usd->default_account->balance;
    my $amount         = 10;
    my $client_id      = $client_usd->loginid;

    $t->await::verify_email({
        type         => "paymentagent_withdraw",
        verify_email => $client_usd->email
    });
    my $token = find_verification_token($client_usd->email);
    ok($token, 'Withdrawal token found');

    my $response = $t->await::paymentagent_withdraw({
        paymentagent_withdraw => 1,
        paymentagent_loginid  => $agent_usd->loginid,
        currency              => 'USD',
        amount                => $amount,
        verification_code     => $token,
        description           => 'A message in a bottle'
    });

    is($response->{error} // 0, 0, 'Successful payment agent withdrawal');
    test_schema('paymentagent_withdraw', $response);
    cmp_ok($client_balance - $amount, '==', $client_usd->default_account->balance, 'Client balance is correct after transfer.');
    $client_balance = $client_usd->default_account->balance;

    check_last_statement($t, $client_token, -$amount, 'withdrawal',
        qr/^Transfer from $client_id to Payment Agent $agent_name Transaction reference: .* Timestamp: .* Client note: A message in a bottle$/,
        $client_balance, $response->{transaction_id});
    check_last_statement(
        $t, $agent_token, $amount, 'deposit',
        qr/^Transfer from $client_id to Payment Agent $agent_name Transaction reference: .* Timestamp: .* Client note: A message in a bottle$/,
        $agent_usd->default_account->balance
    );
};

subtest 'transfer between accounts' => sub {
    my $client_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $client_usd->email,
        residence   => 'id',
    });
    $client_btc->set_default_account('BTC');
    $user_client->add_client($client_btc);
    my $btc_token = BOM::Database::Model::AccessToken->new->create_token($client_btc->loginid, 'test token', ['read', 'payment']);

    populate_exchange_rates({
        USD => 1,
        BTC => 6000,
    });

    $t->await::authorize({authorize => $client_token});
    my $client_balance = $client_usd->default_account->balance;
    my $amount         = 10;
    my $from_id        = $client_usd->loginid;
    my $to_id          = $client_btc->loginid;

    my $response = $t->await::transfer_between_accounts({
        transfer_between_accounts => 1,
        account_from              => $from_id,
        account_to                => $to_id,
        currency                  => 'USD',
        amount                    => $amount
    });

    test_schema('transfer_between_accounts', $response);
    is($response->{error} // 0, 0, 'Successful transfer between account call');
    is($response->{client_to_loginid}, $to_id, 'Correct client_to loginid');
    is($response->{client_to_full_name}, $client_btc->full_name, 'Correct client_to name');
    cmp_ok($client_balance - $amount, '==', $client_usd->default_account->balance, 'Client balance is correct after transfer.');
    $client_balance = $client_usd->default_account->balance;

    check_last_statement($t, $client_token, -$amount, 'withdrawal',
        qr/^Account transfer from $from_id to $to_id. Includes transfer fee of USD .* \(.*%\).$/,
        $client_balance, $response->{transaction_id});
    check_last_statement(
        $t, $btc_token, $client_btc->default_account->balance,
        'deposit',
        qr/^Account transfer from $from_id to $to_id. Includes transfer fee of USD .* \(.*%\).$/,
        $client_btc->default_account->balance
    );
};

sub check_last_statement {
    my ($t, $token, $amount, $action_type, $longcode, $balance, $transaction_id) = @_;

    my $statement_args = {
        "statement"   => 1,
        "description" => 1,
        "limit"       => 1,
        "offset"      => 0
    };

    $t->await::authorize({authorize => $token});

    my $statement_res = $t->await::statement($statement_args);
    test_schema('statement', $statement_res);
    is($statement_res->{statement}->{count}, 1, 'Statement result is not empty');
    is($statement_res->{statement}->{transactions}[0]->{transaction_id}, $transaction_id, 'The same trasaction id in statement') if $transaction_id;
    cmp_ok($statement_res->{statement}->{transactions}[0]->{amount},        '==', $amount,  'Correct amount in statement');
    cmp_ok($statement_res->{statement}->{transactions}[0]->{balance_after}, '==', $balance, 'Correct balance in statement');
    is($statement_res->{statement}->{transactions}[0]->{action_type}, $action_type, 'Correct action type in statement');
    like($statement_res->{statement}->{transactions}[0]->{longcode}, $longcode);
}

sub find_verification_token {
    my $email  = shift;
    my $redis  = BOM::Config::RedisReplicated::redis_read();
    my $tokens = $redis->execute('keys', 'VERIFICATION_TOKEN::*');

    my $json = JSON::MaybeXS->new;
    foreach my $key (@{$tokens}) {
        my $value = $json->decode(Encode::decode_utf8($redis->get($key)));
        return $value->{token} if ($value->{email} eq $email);
    }
    return 0;
}

$t->finish_ok;

done_testing();
