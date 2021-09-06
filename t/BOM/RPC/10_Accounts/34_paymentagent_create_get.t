use strict;
use warnings;

use Test::Most;
use Test::MockModule;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw( :init );
use BOM::Test::RPC::QueueClient;
use BOM::Platform::Context qw (request);

my $c = BOM::Test::RPC::QueueClient->new();

subtest 'paymentagent set and get' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);

    my $set_method = 'paymentagent_create';
    my $set_params = {
        language => 'EN',
        token    => $token
    };
    my $get_params = {
        language => 'EN',
        token    => $token
    };

    my $mock_client = Test::MockModule->new("BOM::User::Client");
    $mock_client->redefine(is_virtual => sub { return 1 });
    $c->call_ok($set_method, $set_params)->has_error->error_message_is('Permission denied.')
        ->error_code_is('PermissionDenied', 'error code is correct for pa_create request with virtul account.');
    $c->call_ok('paymentagent_details', $get_params)->has_error->error_message_is('Permission denied.')
        ->error_code_is('PermissionDenied', 'error code is for pa_details request with virtul account.');
    $mock_client->unmock_all;

    $c->call_ok($set_method, $set_params)->has_error->error_message_is('Please set the currency for your existing account.', 'no-currency error')
        ->error_code_is('NoAccountCurrency', 'error code is correct for an account with no currency.');
    $client->set_default_account('USD');

    subtest 'Input validations' => sub {
        cmp_deeply $c->call_ok($set_method, $set_params)->has_error->result->{error},
            {
            code              => 'InputValidationFailed',
            message_to_client => 'This field is required.',
            details           => {
                fields => bag(
                    'supported_payment_methods', 'information',        'payment_agent_name', 'url',
                    'code_of_conduct_approval',  'commission_deposit', 'commission_withdrawal'
                )}
            },
            'required fields cannot be empty';

        $set_params->{args} = {
            'payment_agent_name'        => '+_',
            'information'               => '   ',
            'url'                       => ' &^% ',
            'commission_withdrawal'     => 'abcd',
            'commission_deposit'        => 'abcd',
            'supported_payment_methods' => ['   ', 'bank_transfer'],
            'code_of_conduct_approval'  => 0,
        };

        is_deeply $c->call_ok($set_method, $set_params)->has_error->result->{error},
            {
            code              => 'InputValidationFailed',
            message_to_client => 'Code of conduct should be accepted.',
            details           => {fields => ['code_of_conduct_approval']}
            },
            'COC approval is required';

        $set_params->{args}->{code_of_conduct_approval} = 1;

        cmp_deeply $c->call_ok($set_method, $set_params)->has_error->result->{error},
            {
            code              => 'InputValidationFailed',
            message_to_client => 'This field must contain at least one alphabetic character.',
            details           => {fields => bag('payment_agent_name', 'information', 'supported_payment_methods')}
            },
            'String values must contain at least one alphabetic character';

        $set_params->{args}->{$_} = 'Valid String' for (qw/payment_agent_name information/);
        $set_params->{args}->{supported_payment_methods} = ['Valid method'];

        cmp_deeply $c->call_ok($set_method, $set_params)->has_error->result->{error},
            {
            code              => 'InputValidationFailed',
            message_to_client => 'The numeric value is invalid.',
            details           => {fields => bag('commission_withdrawal', 'commission_deposit')}
            },
            'Commission must be a valid number.';

        $set_params->{args}->{commission_withdrawal} = -1;
        $set_params->{args}->{commission_deposit}    = 4.0001;

        cmp_deeply $c->call_ok($set_method, $set_params)->has_error->result->{error},
            {
            code              => 'InputValidationFailed',
            message_to_client => 'It must be between 0 and 9.',
            details           => {fields => bag('commission_withdrawal')}
            },
            'Commissions should be in range';

        $set_params->{args}->{commission_withdrawal} = 1;

        cmp_deeply $c->call_ok($set_method, $set_params)->has_error->result->{error},
            {
            code              => 'InputValidationFailed',
            message_to_client => 'Only 2 decimal places are allowed.',
            details           => {fields => bag('commission_deposit')}
            },
            'Commission decimal precision is 2';
        $set_params->{args}->{commission_deposit} = 1;
    };

    $set_params->{args} = {
        'payment_agent_name'        => 'Nobody',
        'information'               => 'Request for pa application',
        'url'                       => 'http://abcd.com',
        'commission_withdrawal'     => 4,
        'commission_deposit'        => 5,
        'supported_payment_methods' => ['Visa', 'bank_transfer'],
        'code_of_conduct_approval'  => 1,
    };

    is my $pa = $client->get_payment_agent, undef, 'Client does not have any payment agent yet';
    $c->call_ok('paymentagent_details', $get_params)
        ->has_no_system_error->has_error->error_message_is('You have not applied for being payment agent yet.')->error_code_is('NoPaymentAgent');

    $c->call_ok($set_method, $set_params)->has_no_system_error->has_no_error('paymentagent_create is called successfully');

    my $min_max         = BOM::Config::PaymentAgent::get_transfer_min_max('USD');
    my $expected_values = {
        'payment_agent_name'        => 'Nobody',
        'url'                       => 'http://abcd.com',
        'email'                     => $client->email,
        'phone'                     => $client->phone,
        'information'               => 'Request for pa application',
        'currency_code'             => 'USD',
        'target_country'            => $client->residence,
        'max_withdrawal'            => $min_max->{maximum},
        'min_withdrawal'            => $min_max->{minimum},
        'commission_deposit'        => 5,
        'commission_withdrawal'     => 4,
        'is_authenticated'          => 0,
        'is_listed'                 => 0,
        'code_of_conduct_approval'  => 1,
        'affiliate_id'              => '',
        'supported_payment_methods' => ['Visa', 'bank_transfer'],
    };
    my $result = $c->call_ok('paymentagent_details', $get_params)->has_no_system_error->has_no_error->result;
    delete $result->{stash};
    is_deeply $result, $expected_values, 'PA get result is correct';

    delete $client->{payment_agent};
    ok $pa = $client->get_payment_agent, 'Client has a payment agent now';
    delete $expected_values->{supported_payment_methods};
    $expected_values->{supported_banks} = 'Visa,bank_transfer';
    is_deeply {
        map { $_ => $pa->$_ } (keys %$expected_values)
    }, $expected_values, 'PA details are correct';

};

subtest 'call with non-empty args' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);
    $client->set_default_account('USD');

    my $email_args;
    my $mock_email = Test::MockModule->new('BOM::RPC::v3::Accounts');
    $mock_email->redefine(send_email => sub { $email_args = shift });

    my $set_params = {
        language => 'EN',
        token    => $token
    };
    my $get_params = {
        language => 'EN',
        token    => $token
    };
    $set_params->{args} = {
        'payment_agent_name'        => 'Smith',
        'url'                       => 'http://test.deriv.com',
        'email'                     => 'abc@test.com',
        'phone'                     => '233445',
        'information'               => 'just for test',
        'currency_code'             => 'EUR',
        'target_country'            => 'de',
        'max_withdrawal'            => 3,
        'min_withdrawal'            => 2,
        'commission_withdrawal'     => 4,
        'commission_deposit'        => 5,
        'is_authenticated'          => 1,
        'is_listed'                 => 1,
        'affiliate_id'              => 'test token',
        'supported_payment_methods' => ['Visa'],
        'code_of_conduct_approval'  => 1,
        'affiliate_id'              => 'abcd1234',
    };

    $c->call_ok('paymentagent_create', $set_params)->has_no_error;

    my $expected_values = {
        'payment_agent_name'        => 'Smith',
        'url'                       => 'http://test.deriv.com',
        'email'                     => 'abc@test.com',
        'phone'                     => '233445',
        'information'               => 'just for test',
        'currency_code'             => 'EUR',
        'target_country'            => 'de',
        'max_withdrawal'            => 3,
        'min_withdrawal'            => 2,
        'commission_withdrawal'     => 4,
        'commission_deposit'        => 5,
        'is_authenticated'          => 0,
        'is_listed'                 => 0,
        'supported_payment_methods' => ['Visa'],
        'code_of_conduct_approval'  => 1,
        'affiliate_id'              => 'abcd1234',
    };
    my $result = $c->call_ok('paymentagent_details', $get_params)->has_no_system_error->has_no_error->result;
    delete $result->{stash};
    is_deeply $result, $expected_values, 'PA get result is correct';

    delete $expected_values->{supported_payment_methods};
    $expected_values->{supported_banks} = 'Visa';

    delete $client->{payment_agent};
    ok my $pa = $client->get_payment_agent, 'Client has a payment agent now';
    is_deeply {
        map { $_ => $pa->$_ } (keys %$expected_values),
    }, $expected_values, 'PA details are correct';

    ok $email_args, 'An email is sent';
    my $brand = request->brand;
    is $email_args->{from},    $brand->emails('system'),      'email source is correct';
    is $email_args->{to},      $brand->emails('pa_livechat'), 'email receiver is correct';
    is $email_args->{subject}, "Payment agent application submitted by " . $client->loginid, 'Email subject is correct';
    like $email_args->{message}->[0], qr/$_: $expected_values->{$_}/, "The field $_ is included in the email body" for keys %$expected_values;
};

subtest 'paymentagent create erors' => sub {

    my $mock_landingcompany = Test::MockModule->new('LandingCompany');
    $mock_landingcompany->mock('allows_payment_agents', sub { return 0; });

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client->set_default_account('USD');
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);

    my $set_params = {
        language => 'EN',
        token    => $token
    };
    $set_params->{args} = {
        'payment_agent_name'        => 'John',
        'url'                       => 'http://john.deriv.com',
        'email'                     => 'john@test.com',
        'phone'                     => '23344577',
        'information'               => 'just for test',
        'currency_code'             => 'USD',
        'target_country'            => 'de',
        'max_withdrawal'            => 3,
        'min_withdrawal'            => 2,
        'commission_withdrawal'     => 4,
        'commission_deposit'        => 5,
        'is_authenticated'          => 1,
        'is_listed'                 => 1,
        'supported_payment_methods' => ['Visa'],
        'code_of_conduct_approval'  => 1,
        'affiliate_id'              => 'abcd12347',
    };

    $c->call_ok('paymentagent_create', $set_params)
        ->has_no_system_error->has_error->error_message_is("The payment agent facility is not available for this account.")
        ->error_code_is("PaymentAgentNotAvailable");

    $mock_landingcompany->mock('allows_payment_agents', sub { return 1; });

    $c->call_ok('paymentagent_create', $set_params)->has_no_system_error->has_no_error("paymentagent_create is called successfully");

    $c->call_ok('paymentagent_create', $set_params)
        ->has_no_system_error->has_error->error_message_is("You've already submitted a payment agent application request.")
        ->error_code_is("PaymentAgentAlreadyExists");

    $mock_landingcompany->unmock_all;
};

done_testing();
