use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;
use Test::FailWarnings;
use Test::Exception;
use Test::MockTime qw(restore_time set_fixed_time);
use Test::Deep;
use BOM::User::Client::PaymentAgent;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Customer;
use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates);
use BOM::Test::Helper::Client        qw( top_up );
use BOM::Database::Model::OAuth;
use BOM::User::Password;
use BOM::Config::Runtime;
use BOM::Config::PaymentAgent;
use BOM::Config::Redis;

my $test_customer = BOM::Test::Customer->create(
    clients => [{
            name        => 'CR',
            broker_code => 'CR',
        }]);
my $test_client = $test_customer->get_client_object('CR');

my $test_customer_pa = BOM::Test::Customer->create(
    email_verified => 1,
    clients        => [{
            name            => 'CR',
            broker_code     => 'CR',
            default_account => 'USD',
        }]);
my $pa_client = $test_customer_pa->get_client_object('CR');

# make him a payment agent
my $object_pa = $pa_client->payment_agent({
    payment_agent_name    => 'Joe',
    email                 => 'joe@example.com',
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    status                => 'authorized',
    currency_code         => 'USD',
    is_listed             => 't',
});
$pa_client->save;
$pa_client->get_payment_agent->set_countries(['id', 'pk']);
my $target_countries  = $pa_client->get_payment_agent->get_countries;
my $expected_result_1 = ['id', 'pk'];
is_deeply($target_countries, $expected_result_1, "returned correct countries");
$pa_client->payment_agent->information("The payment agent information is updated");
$pa_client->save;
is($pa_client->payment_agent->information, 'The payment agent information is updated', 'PA information is correct');
$target_countries = $pa_client->get_payment_agent->get_countries;
is_deeply($target_countries, $expected_result_1, "returned correct countries after update payment agent table");
#Added to check backward compatibility.
#TO-DO : must be removed when in future trigger on target_country column in payment_Agent is removed
$pa_client->payment_agent->target_country("vn");
$pa_client->save;
$target_countries = $pa_client->get_payment_agent->get_countries;
is_deeply($target_countries, ['vn'], "when target_country is updated now only one country i. e vn should be available.");
# set the countries again for normal flow
$pa_client->get_payment_agent->set_countries(['id', 'pk']);
my $payment_agent_1 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'id',
    broker_code  => 'CR',
    currency     => 'USD',
    is_listed    => 't',
);

ok($payment_agent_1->{'CR10001'});
ok($payment_agent_1->{'CR10001'}->currency_code eq 'USD');
ok($payment_agent_1->{'CR10001'}->is_listed == 1);

my $payment_agent_2 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'id',
    broker_code  => 'CR',
    currency     => 'USD',
    is_listed    => 'f',
);
is($payment_agent_2->{'CR10001'}, undef, 'agent not returned when is_listed is false');

my $payment_agent_3 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'pk',
    broker_code  => 'CR',
    currency     => 'USD',
);

is($payment_agent_3->{'CR10001'}->client_loginid, 'CR10001', 'agent is allowed two countries so getting result even for country pk');
ok($payment_agent_3->{'CR10001'}->currency_code eq 'USD');
ok($payment_agent_3->{'CR10001'}->is_listed == 1);

my $payment_agent_4 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'id',
    broker_code  => 'CR',
);
ok($payment_agent_4->{'CR10001'});
ok($payment_agent_4->{'CR10001'}->currency_code eq 'USD');
ok($payment_agent_4->{'CR10001'}->is_listed == 1);

my $pa_client_2 = $test_customer_pa->create_client(
    name            => 'CR2',
    broker_code     => 'CR',
    default_account => 'USD'
);

# make him a payment agent
my $object_pa2 = $pa_client_2->payment_agent({
    payment_agent_name    => 'Joe 2',
    email                 => 'joe@example.com',
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    status                => 'authorized',
    currency_code         => 'USD',
    is_listed             => 'f',
});
$pa_client_2->save;

$pa_client_2->get_payment_agent->set_countries(['id', 'pk']);
my $payment_agent_5 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'id',
    broker_code  => 'CR',
    currency     => 'USD',
    is_listed    => 't',
);
is($payment_agent_5->{'CR10002'}, undef);

my $payment_agent_6 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'id',
    broker_code  => 'CR',
    currency     => 'USD',
    is_listed    => 'f',
);
ok($payment_agent_6->{'CR10002'});
ok($payment_agent_6->{'CR10002'}->currency_code eq 'USD');
ok($payment_agent_6->{'CR10002'}->is_listed == 0);

my $payment_agent_7 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'id',
    broker_code  => 'CR',
    currency     => 'USD',
);
ok($payment_agent_7->{'CR10002'}, 'Agent returned because is_listed is not supplied');
ok($payment_agent_7->{'CR10002'}->currency_code eq 'USD');
ok($payment_agent_7->{'CR10002'}->is_listed == 0);

my $payment_agent_8 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'id',
    broker_code  => 'CR',
);
ok($payment_agent_8->{'CR10002'}, 'Agent returned because is_listed is not supplied');
ok($payment_agent_8->{'CR10002'}->currency_code eq 'USD');
ok($payment_agent_8->{'CR10002'}->is_listed == 0);

dies_ok { BOM::User::Client::PaymentAgent->get_payment_agents() };

# Add new payment agent to check validation for adding multiple target_countries
my $pa_client_3 = $test_customer_pa->create_client(
    name            => 'CR3',
    broker_code     => 'CR',
    default_account => 'USD'
);

# make him a payment agent
$pa_client_3->payment_agent({
    payment_agent_name    => 'Joe 3',
    email                 => 'joe@example.com',
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    status                => 'authorized',
    currency_code         => 'USD',
    is_listed             => 'f',
});
$pa_client_3->save;
BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries(['us']);
is($pa_client_3->get_payment_agent->set_countries(['id', 'us']), undef, 'Suspended country could not be added');
BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([]);
is($pa_client_3->get_payment_agent->set_countries(['id', 'any_country']), undef, 'Invalid country could not be added');
is($pa_client_3->get_payment_agent->set_countries(['id', 'at']),          undef, 'Countries from same landing company as payment agent is allowed');

subtest 'linked details' => sub {
    my %test_data = (
        urls                      => [{url          => 'https://wwww.pa.com'}, {url          => 'https://wwww.nowhere.com'}],
        phone_numbers             => [{phone_number => '+12345678'},           {phone_number => '+87654321'}],
        supported_payment_methods => [],
    );

    my $pa = $pa_client->get_payment_agent;
    for my $field (sort keys %test_data) {
        $pa->$field($test_data{$field});
        $pa->save;
        delete $pa->{$field};

        # reload from db
        cmp_deeply $pa->$field, bag($test_data{$field}->@*), "$field is correctly retrieved";
    }
};

subtest 'get payment agents by name' => sub {
    my $pa     = $test_client->set_payment_agent();
    my $result = $pa->get_payment_agents_by_name('ADFASDF');
    is $result->@*, 0, 'No result for non-existing name';

    $result = $pa->get_payment_agents_by_name('Joe');
    is $result->@*,                    1,                   'One row is found';
    is $result->[0]->{client_loginid}, $pa_client->loginid, 'Client loginid is correct';

    $result = $pa->get_payment_agents_by_name('Joe 2');
    is $result->@*,                    1,                     'One row is found';
    is $result->[0]->{client_loginid}, $pa_client_2->loginid, 'Client loginid is correct';

    $result = $pa->get_payment_agents_by_name('jOE 2');
    is $result->@*,                    1,                     'The search is case insensitive';
    is $result->[0]->{client_loginid}, $pa_client_2->loginid, 'Client loginid is correct';
};

subtest 'validate payment agent details' => sub {
    my $test_customer = BOM::Test::Customer->create(
        email_verified => 1,
        clients        => [{
                name        => 'CR',
                broker_code => 'CR',
            }]);
    my $client1 = $test_customer->get_client_object('CR');

    my $pa = $client1->set_payment_agent();

    my $mock_client = Test::MockModule->new("BOM::User::Client");
    $mock_client->redefine(is_virtual => sub { return 1 });
    like exception { $pa->validate_payment_agent_details() }, qr/PermissionDenied/, 'Virtual clients do not have permission for setting';
    $mock_client->unmock_all;

    like exception { $pa->validate_payment_agent_details() }, qr/NoAccountCurrency/, 'Client currency cannot be empty';
    $client1->set_default_account('USD');

    my $mock_user = Test::MockModule->new('BOM::User');
    $mock_user->redefine(is_payment_agents_suspended_in_country => sub { return 1 });
    like exception { $pa->validate_payment_agent_details() }, qr/PaymentAgentsSupended/, 'Payment agents should not be empty';
    $mock_user->unmock_all;

    cmp_deeply exception { $pa->validate_payment_agent_details() },
        {
        'code'    => 'RequiredFieldMissing',
        'details' => {
            fields => bag(
                'payment_agent_name', 'urls', 'information', 'supported_payment_methods',
                'commission_deposit', 'commission_withdrawal', 'code_of_conduct_approval'
            )}
        },
        'Payment required fileds are returned';

    my %args = (
        'payment_agent_name'        => 'Nobody',
        'information'               => 'Request for pa application',
        'phone_numbers'             => [{phone_number => $client1->phone}],
        'urls'                      => [{url          => 'http://abcd.com'}],
        'commission_withdrawal'     => 4,
        'commission_deposit'        => 5,
        'supported_payment_methods' => [map { +{payment_method => $_} } qw/Visa bank_transfer/],
        'code_of_conduct_approval'  => 0,
    );

    is_deeply exception { $pa->validate_payment_agent_details(%args) },
        {
        'code'    => 'CodeOfConductNotApproved',
        'details' => {
            fields => ['code_of_conduct_approval'],
        }
        },
        'Code if conduct applroval is required';

    $args{code_of_conduct_approval} = 1;

    for my $name (qw/payment_agent_name information/) {
        for my $value ('_ -+,.', '_', '+', ',', '.') {
            is_deeply exception { $pa->validate_payment_agent_details(%args, $name => $value) },
                {
                'code'    => 'InvalidStringValue',
                'details' => {fields => [$name]}
                },
                "Expected failure for field: $name, value: <$value>";
        }
    }

    for my $name (qw/urls supported_payment_methods phone_numbers/) {
        for my $value ([], '') {
            is_deeply exception { $pa->validate_payment_agent_details(%args, $name => $value) },
                {
                'code'    => 'RequiredFieldMissing',
                'details' => {fields => [$name]}
                },
                "Expected failure for field: $name, empty value: <$value>";
        }

        is_deeply exception { $pa->validate_payment_agent_details(%args, $name => 'abcd') },
            {
            'code'    => 'InvalidArrayValue',
            'details' => {fields => [$name]}
            },
            "Expected failure for field: $name, scalar value";

        my $element_attriblute = $pa->details_main_field->{$name};
        is_deeply exception { $pa->validate_payment_agent_details(%args, $name => [{$element_attriblute => '  '}, {$element_attriblute => 'abcd'}]) },
            {
            'code'    => 'InvalidStringValue',
            'details' => {fields => [$name]}
            },
            "Expected failure for field: $name, empty string in array";

        next if $name eq 'phone_numbers';

        is_deeply exception { $pa->validate_payment_agent_details(%args, $name => [{$element_attriblute => '<>!@#$433'}]) },
            {
            'code'    => 'InvalidStringValue',
            'details' => {fields => [$name]}
            },
            "Expected failure for field: $name, no alphabetic character";
    }

    for my $name (qw/commission_withdrawal commission_deposit/) {
        is_deeply exception { $pa->validate_payment_agent_details(%args, $name => 'abcd') },
            {
            'code'    => 'InvalidNumericValue',
            'details' => {fields => [$name]}
            },
            "Invalid commission value: $name, value: abcd";

        for my $value (-1, 9.1) {
            is_deeply exception { $pa->validate_payment_agent_details(%args, $name => $value) },
                {
                code    => 'ValueOutOfRange',
                details => {fields => [$name]},
                params  => [0, 9],
                },
                "Commission $name value $value is out of range";
        }

        is_deeply exception { $pa->validate_payment_agent_details(%args, $name => 3.001) },

            {
            'code'    => 'TooManyDecimalPlaces',
            'details' => {fields => [$name]},
            'params'  => [2],
            },
            "Invalid commission $name, value: 3.001";

    }

    set_fixed_time(1000);
    my $min_max         = BOM::Config::PaymentAgent::get_transfer_min_max('USD');
    my $expected_result = {
        'payment_agent_name'            => 'Nobody',
        'email'                         => $client1->email,
        'phone_numbers'                 => [{phone_number => $client1->phone}],
        'summary'                       => '',
        'information'                   => 'Request for pa application',
        'currency_code'                 => 'USD',
        'target_country'                => $client1->residence,
        'urls'                          => [{url => 'http://abcd.com'}],
        'max_withdrawal'                => $min_max->{maximum},
        'min_withdrawal'                => $min_max->{minimum},
        'commission_deposit'            => 5,
        'commission_withdrawal'         => 4,
        'supported_payment_methods'     => [map { +{payment_method => $_} } qw/Visa bank_transfer/],
        'code_of_conduct_approval'      => 1,
        'affiliate_id'                  => '',
        'code_of_conduct_approval_time' => 1000
    };

    my $result = $pa->validate_payment_agent_details(%args);
    is_deeply $result, $expected_result, 'Expected default values are returned - coc approval is set to current time';

    $result = $pa->validate_payment_agent_details(%args, payment_agent_name => " Nobody  ");
    is_deeply $result,
        {
        'payment_agent_name'            => 'Nobody',
        'email'                         => $client1->email,
        'phone_numbers'                 => [{phone_number => $client1->phone}],
        'summary'                       => '',
        'information'                   => 'Request for pa application',
        'currency_code'                 => 'USD',
        'target_country'                => $client1->residence,
        'urls'                          => [{url => 'http://abcd.com'}],
        'max_withdrawal'                => $min_max->{maximum},
        'min_withdrawal'                => $min_max->{minimum},
        'commission_deposit'            => 5,
        'commission_withdrawal'         => 4,
        'supported_payment_methods'     => [map { +{payment_method => $_} } qw/Visa bank_transfer/],
        'code_of_conduct_approval'      => 1,
        'affiliate_id'                  => '',
        'code_of_conduct_approval_time' => 1000,
        },
        'Expected default values are returned - payment methods and PA name are trimmed.';

    $args{payment_agent_name} = 'Joe';
    is_deeply exception { $pa->validate_payment_agent_details(%args) },
        {
        'code'    => 'DuplicateName',
        'message' => "The name <Joe> is already taken by " . $pa_client->loginid,
        'details' => {
            fields => ['payment_agent_name'],
        }
        },
        'Duplicate names are not allowed';

    %args = (
        'payment_agent_name'            => 'Nobody',
        'email'                         => 'abcd@binary.com',
        'phone_numbers'                 => [{phone_number => '1234'}],
        'summary'                       => 'I am a test pa',
        'information'                   => 'Request for pa application',
        'currency_code'                 => 'EUR',
        'target_country'                => 'de',
        'urls'                          => [{url => 'http://abcd.com'}],
        'commission_withdrawal'         => 4,
        'commission_deposit'            => 5,
        'max_withdrawal'                => 100,
        'commission_deposit'            => 1,
        'commission_withdrawal'         => 3,
        'min_withdrawal'                => 10,
        'status'                        => 'authorized',
        'is_listed'                     => 1,
        'supported_payment_methods'     => [map { +{payment_method => $_} } qw/Visa bank_transfer/],
        'code_of_conduct_approval'      => 1,
        'affiliate_id'                  => '123abcd',
        'code_of_conduct_approval_time' => 1000,
        'services_allowed_comments'     => 'This PA is my sweetheart',
    );

    @args{qw(payment_agent_name min_withdrawal max_withdrawal)} = ('test name', -1, -1);
    is_deeply exception { $pa->validate_payment_agent_details(%args) },
        {
        'code'    => 'MinWithdrawalIsNegative',
        'details' => {
            fields => ['min_withdrawal'],
        }
        },
        'Minimum cant be zero';
    $args{min_withdrawal} = 1;
    cmp_deeply exception { $pa->validate_payment_agent_details(%args) },
        {
        'code'    => 'MinWithdrawalIsNegative',
        'details' => {
            fields => bag('min_withdrawal', 'max_withdrawal'),
        }
        },
        'Max must be larger than min';
    $args{max_withdrawal} = 2;

    for my $commission (qw/commission_deposit commission_withdrawal/) {
        cmp_deeply exception { $pa->validate_payment_agent_details(%args, $commission => 9.01) },
            {
            'code'    => ignore(),
            'details' => {
                fields => [$commission],
            },
            'params' => [0, 9]
            },
            "$commission should not exceed maximum (9)";
    }

    $args{commission_withdrawal} = 0;

    lives_ok { $object_pa->validate_payment_agent_details(%args, payment_agent_name => $object_pa->payment_agent_name) }
    'No error if pa name is the same as the PA itself';
    lives_ok { $object_pa->validate_payment_agent_details(%args, payment_agent_name => $object_pa2->payment_agent_name) }
    'No error if pa name is the same as one of sibling PAs';

    lives_ok { $pa->validate_payment_agent_details(%args) } 'PA arguments are valid';

    subtest 'Code of conduct approval time' => sub {
        $result = $pa->validate_payment_agent_details(%args);
        is_deeply($result, \%args, 'Non-empty args are not changed');

        $result = $pa->validate_payment_agent_details(
            %args,
            code_of_conduct_approval => 0,
            skip_coc_validation      => 1,
        );
        is_deeply(
            $result,
            {
                %args,
                code_of_conduct_approval      => 0,
                code_of_conduct_approval_time => undef
            },
            'Code of conduct is not approved and approval time is set to null'
        );

        my $existing_pa = $pa_client->get_payment_agent;
        $existing_pa->code_of_conduct_approval_time(2000);
        $existing_pa->code_of_conduct_approval(0);
        $existing_pa->save;
        $result = $pa->validate_payment_agent_details(
            %args,
            code_of_conduct_approval => 0,
            skip_coc_validation      => 1
        );
        is_deeply(
            $result,
            {
                %args,
                code_of_conduct_approval      => 0,
                code_of_conduct_approval_time => undef
            },
            'Code of conduct undefined if coc is not approved (even when for existing pa)'
        );

        $result = $pa->validate_payment_agent_details(%args);
        is_deeply($result, {%args, code_of_conduct_approval_time => 1000}, 'COC approval time is set to current time if is not already approved');
        $existing_pa->code_of_conduct_approval(0);
        $existing_pa->save;
        $result = $pa->validate_payment_agent_details(%args);
        is_deeply($result, {%args, code_of_conduct_approval_time => 1000}, 'COC approval time is not changed if it is already approved');
    };

    restore_time();
};

subtest 'copy payment agent details and related' => sub {
    my $test_customer = BOM::Test::Customer->create(
        clients => [{
                name            => 'CR1',
                broker_code     => 'CR',
                default_account => 'USD',
            },
            {
                name            => 'CR2',
                broker_code     => 'CR',
                default_account => 'BTC',
            }]);
    my $client1 = $test_customer->get_client_object('CR1');
    my $client2 = $test_customer->get_client_object('CR2');

    my $args1 = {
        'payment_agent_name'            => 'Copy PA 1',
        'email'                         => 'pa1@binary.com',
        'phone_numbers'                 => [{phone_number => '1111'}],
        'summary'                       => 'I am a test pa 1',
        'information'                   => 'Request for pa application 1',
        'currency_code'                 => 'USD',
        'target_country'                => 'af,ch',
        'urls'                          => [{url => 'http://aaaa.com'}],
        'min_withdrawal'                => 10,
        'max_withdrawal'                => 100,
        'commission_deposit'            => 1,
        'commission_withdrawal'         => 3,
        'status'                        => 'authorized',
        'is_listed'                     => 1,
        'supported_payment_methods'     => [{payment_method => 'Visa'}],
        'code_of_conduct_approval'      => 1,
        'affiliate_id'                  => '1111aaaa',
        'code_of_conduct_approval_time' => '2020-01-01T00:00:00',
        'risk_level'                    => 'low'
    };
    my $pa1 = $client1->set_payment_agent();
    $pa1->$_($args1->{$_}) for keys %$args1;
    $pa1->save;
    ok $client1->get_payment_agent->set_countries([qw/af ch/]), 'Countries are set';

    my @pa_list = $client1->get_payment_agent->sibling_payment_agents;
    is scalar @pa_list,                 1,           'There is one sibling payment agent';
    is $pa_list[0]->payment_agent_name, 'Copy PA 1', 'PA name is correct';

    my $args2 = {
        'payment_agent_name'            => 'Copy PA 2',
        'email'                         => 'pa2@binary.com',
        'phone_numbers'                 => [{phone_number => '22222'}],
        'summary'                       => 'I am a test pa 2',
        'information'                   => 'Request for pa application 2',
        'currency_code'                 => 'BTC',
        'target_country'                => 'id,in',
        'urls'                          => [{url => 'http://bbbbbb.com'}],
        'min_withdrawal'                => 0.00001,
        'max_withdrawal'                => 0.1,
        'commission_deposit'            => 4,
        'commission_withdrawal'         => 5,
        'status'                        => undef,
        'is_listed'                     => 0,
        'supported_payment_methods'     => [{payment_method => 'Bank note'}],
        'code_of_conduct_approval'      => 0,
        'affiliate_id'                  => '2222bbbbb',
        'code_of_conduct_approval_time' => '2021-02-02',
        'risk_level'                    => 'low'
    };
    my $pa2 = $client2->set_payment_agent();
    $pa2->$_($args2->{$_}) for keys %$args2;
    $pa2->save;
    $client2->get_payment_agent->set_countries([qw/id in/]);

    # copy to siblings
    my $pa_1 = $client1->get_payment_agent;
    @pa_list = $pa_1->sibling_payment_agents;
    is scalar @pa_list, 2, 'There are two sibling payment agents';
    is_deeply [map { $_->payment_agent_name } @pa_list], ['Copy PA 1', 'Copy PA 2'], 'PA names are correct';

    like exception { $pa_1->copy_details_to($client2->get_payment_agent) }, qr/No rate available to convert BTC to USD/,
        'Error if there is no exchange rate';
    populate_exchange_rates({BTC => 10000});
    $pa_1->copy_details_to($client2->get_payment_agent);

    my $pa_2 = $client2->get_payment_agent;
    is_deeply { $pa_2->%{keys %$args1} },
        {
        %$args1,
        currency_code  => 'BTC',
        min_withdrawal => '0.00100000',
        max_withdrawal => '0.01000000'
        },
        'Everything is copied except loginid - limits are converted according to exchange rates';
    is_deeply $pa_2->get_countries(), [qw/af ch/], 'Countries are also copied.';
    is_deeply $pa_1->get_countries(), [qw/af ch/], 'Souce countries are correct.';

    # convert withdrawal limits
    is_deeply $pa_1->convert_withdrawal_limits('BTC'),
        {
        min_withdrawal => '0.00100000',
        max_withdrawal => '0.01000000'
        };
    is_deeply $client2->get_payment_agent->convert_withdrawal_limits('USD'),
        {
        min_withdrawal => '10.00',
        max_withdrawal => '100.00'
        };
};

subtest 'services allowed' => sub {
    my $pa = $pa_client->get_payment_agent;

    my $mock_pa      = Test::MockModule->new('BOM::User::Client::PaymentAgent');
    my $tier_details = {};
    $mock_pa->redefine(tier_details => sub { $tier_details });

    for my $status (undef, 'applied') {
        $mock_pa->redefine(status => $status);

        ok $pa->service_is_allowed('dummy service'), 'unknown service is allowed for unauthorized PA';
        for my $service (BOM::User::Client::PaymentAgent::RESTRICTED_SERVICES->@*) {
            ok $pa->service_is_allowed($service), "Restricted service $service is allowed for unauthorized PA";
        }
    }

    $mock_pa->redefine(status => 'authorized');
    for my $service (BOM::User::Client::PaymentAgent::RESTRICTED_SERVICES->@*) {
        ok $pa->service_is_allowed('dummy service'), 'unknown service is allowed for authorized PA';

        ok !$pa->service_is_allowed($service), "Restricted service $service is blocked for authorized PA";

        $tier_details->{$service} = 1;
        ok $pa->service_is_allowed($service), "$service is allowed for authorized PA if it's added to the list";
        delete $tier_details->{$service};
    }
};

subtest 'newly_authorized' => sub {
    my $pa    = $pa_client->get_payment_agent;
    my $key   = 'PAYMENT_AGENT::NEWLY_AUTHORIZED::' . $pa_client->loginid;
    my $redis = BOM::Config::Redis::redis_replicated_read();

    is $pa->newly_authorized,    0, '0 by default';
    is $pa->newly_authorized(1), 1, 'set to 1';
    cmp_ok $redis->ttl($key), '>', 2000000, 'ttl of key set';
    is $pa->newly_authorized,    1,     'returns 1';
    is $pa->newly_authorized(0), 0,     'set to 0';
    is $pa->newly_authorized,    0,     'returns 0';
    is $redis->get($key),        undef, 'key is removed';
};

done_testing();
