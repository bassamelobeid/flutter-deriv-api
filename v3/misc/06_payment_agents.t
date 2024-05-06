use strict;
use warnings;

use Test::More;
use Test::Deep;
use BOM::Test::Helper qw/build_wsapi_test/;
use await;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw(top_up);
use BOM::Platform::Token::API;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

$app_config->set({'payment_agents.initial_deposit_per_country' => '{ "default": 100 }'});

my $t = build_wsapi_test();

subtest 'paymentagent create and info' => sub {
    my $email = 'pa@test.com';

    my $user = BOM::User->create(
        email    => $email,
        password => 'x'
    );
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });

    $client->account('USD');

    $user->update_email_fields(email_verified => 't');
    $user->add_client($client);

    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test', ['admin']);

    $t->await::authorize({authorize => $token});

    my %params = (
        'phone_numbers'             => [{'phone_number' => '+923-22-23-13'}],
        'commission_deposit'        => 2,
        'commission_withdrawal'     => 3,
        'supported_payment_methods' => [{'payment_method' => 'MasterCard'}, {'payment_method' => 'Visa'}],
        'payment_agent_name'        => 'Joe Joy',
        'code_of_conduct_approval'  => 1,
        'information'               => 'The best person you can find',
        'affiliate_id'              => '1231234',
        'urls'                      => [{'url' => 'https://abc.com'}],
        'email'                     => 'joe@joy.com',
    );

    my $resp = $t->await::paymentagent_details({paymentagent_details => 1});
    cmp_deeply(
        $resp->{paymentagent_details},
        {
            can_apply             => 0,
            eligibilty_validation => ignore(),
        },
        'paymentagent_details correct response for non-eligible client'
    );

    $resp = $t->await::paymentagent_create({paymentagent_create => 1, %params});
    ok $resp->{error}, 'paymentagent_create gets error for non-eligible client';

    top_up($client, 'USD', 1000);
    $client->status->set('age_verification', 'x', 'x');

    $client->db->dbic->dbh->do(
        "INSERT INTO betonmarkets.client_authentication_method (client_loginid, authentication_method_code, status) 
        VALUES ('" . $client->loginid . "', 'ID_ONLINE', 'pass')"
    );

    $resp = $t->await::paymentagent_details({paymentagent_details => 1});
    cmp_deeply($resp->{paymentagent_details}, {can_apply => 1}, 'paymentagent_details correct response for eligible client');

    $resp = $t->await::paymentagent_create({paymentagent_create => 1, %params});
    ok !$resp->{error}, 'paymentagent_create has no error for eligible client';

    $resp = $t->await::paymentagent_details({paymentagent_details => 1});
    cmp_deeply($resp->{paymentagent_details}, superhashof(\%params), 'paymentagent_details correct response for applied pa');
};

subtest 'payment agent withdraw justification' => sub {

    my $user = BOM::User->create(
        email    => 'testing@forthewin.com',
        password => 'x'
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $user->email,
        binary_user_id => $user->id,
    });

    $user->add_client($client);

    my $params = {
        paymentagent_withdraw_justification => 1,
        message                             => 'I want my money',
    };

    for my $scope (qw(read trade admin trading_information)) {
        my $token = BOM::Platform::Token::API->new->create_token($client->loginid, $scope, [$scope]);
        $t->await::authorize({authorize => $token});
        my $resp = $t->await::paymentagent_withdraw_justification($params);

        is $resp->{error}{code}, 'PermissionDenied', "PermissionDenied error with $scope scope";
    }

    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'payments', ['payments']);
    $t->await::authorize({authorize => $token});
    my $resp = $t->await::paymentagent_withdraw_justification($params);
    is $resp->{paymentagent_withdraw_justification}, 1, 'successful response with payments scope';
};

$t->finish_ok;

done_testing();
