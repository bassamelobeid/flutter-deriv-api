use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;
use Test::FailWarnings;
use Test::Exception;
use Test::MockTime qw(restore_time set_absolute_time);
use Test::Deep;
use BOM::User::Client::PaymentAgent;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( top_up );
use BOM::Database::Model::OAuth;
use BOM::User::Password;
use BOM::Config::Runtime;
use BOM::Config::PaymentAgent;

my $email       = 'JoeSmith@binary.com';
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email($email);
$test_client->save;
BOM::User->create(
    email    => $test_client->email,
    password => 'test',
)->add_client($test_client);

my $pa_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$pa_client->email('pa+' . $email);
$pa_client->set_default_account('USD');
$pa_client->save;
my $user = BOM::User->create(
    email    => $pa_client->email,
    password => 'test',
);
$user->add_client($pa_client);

# make him a payment agent
my $object_pa = $pa_client->payment_agent({
    payment_agent_name    => 'Joe',
    url                   => 'http://www.example.com/',
    email                 => 'joe@example.com',
    phone                 => '+12345678',
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    is_authenticated      => 't',
    currency_code         => 'USD',
    is_listed             => 't'
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
ok($payment_agent_1->{'CR10001'}->{'currency_code'} eq 'USD');
ok($payment_agent_1->{'CR10001'}->{'is_listed'} == 1);

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

is($payment_agent_3->{'CR10001'}->{'client_loginid'}, 'CR10001', 'agent is allowed two coutries so getting result even for country pk');
ok($payment_agent_3->{'CR10001'}->{'currency_code'} eq 'USD');
ok($payment_agent_3->{'CR10001'}->{'is_listed'} == 1);

my $payment_agent_4 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'id',
    broker_code  => 'CR',
);
ok($payment_agent_4->{'CR10001'});
ok($payment_agent_4->{'CR10001'}->{'currency_code'} eq 'USD');
ok($payment_agent_4->{'CR10001'}->{'is_listed'} == 1);

# Add new payment agent with is_listed = false
my $pa_client_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$pa_client_2->email('pa+' . $email);
$pa_client_2->set_default_account('USD');
$pa_client_2->save;
$user->add_client($pa_client_2);

# make him a payment agent
my $object_pa2 = $pa_client_2->payment_agent({
    payment_agent_name    => 'Joe 2',
    url                   => 'http://www.example.com/',
    email                 => 'joe@example.com',
    phone                 => '+12345678',
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    is_authenticated      => 't',
    currency_code         => 'USD',
    is_listed             => 'f'
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
ok($payment_agent_6->{'CR10002'}->{'currency_code'} eq 'USD');
ok($payment_agent_6->{'CR10002'}->{'is_listed'} == 0);

my $payment_agent_7 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'id',
    broker_code  => 'CR',
    currency     => 'USD',
);
ok($payment_agent_7->{'CR10002'}, 'Agent returned because is_listed is not supplied');
ok($payment_agent_7->{'CR10002'}->{'currency_code'} eq 'USD');
ok($payment_agent_7->{'CR10002'}->{'is_listed'} == 0);

my $payment_agent_8 = BOM::User::Client::PaymentAgent->get_payment_agents(
    country_code => 'id',
    broker_code  => 'CR',
);
ok($payment_agent_8->{'CR10002'}, 'Agent returned because is_listed is not supplied');
ok($payment_agent_8->{'CR10002'}->{'currency_code'} eq 'USD');
ok($payment_agent_8->{'CR10002'}->{'is_listed'} == 0);

dies_ok { BOM::User::Client::PaymentAgent->get_payment_agents() };

# Add new payment agent to check validation for adding multiple target_countries
my $pa_client_3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$pa_client_3->email('pa+' . $email);
$pa_client_3->set_default_account('USD');
$pa_client_3->save;
$user->add_client($pa_client_3);
# make him a payment agent
$pa_client_3->payment_agent({
    payment_agent_name    => 'Joe 3',
    url                   => 'http://www.example.com/',
    email                 => 'joe@example.com',
    phone                 => '+12345678',
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    is_authenticated      => 't',
    currency_code         => 'USD',
    is_listed             => 'f'
});
$pa_client_3->save;
BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries(['us']);
is($pa_client_3->get_payment_agent->set_countries(['id', 'us']), undef, 'Suspended country could not be added');
BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([]);
is($pa_client_3->get_payment_agent->set_countries(['id', 'any_country']), undef, 'Invalid country could not be added');
is($pa_client_3->get_payment_agent->set_countries(['id', 'at']),          undef, 'Countries from same landing company as payment agent is allowed');

subtest 'get payment agents by name' => sub {
    my $pa     = $test_client->set_payment_agent();
    my $result = $pa->get_payment_agents_by_name('ADFASDF');
    is $result->@*, 0, 'No result for non-existing name';

    $result = $pa->get_payment_agents_by_name('Joe');
    is $result->@*, 1, 'One row is found';
    is $result->[0]->{client_loginid}, $pa_client->loginid, 'Client loginid is correct';

    $result = $pa->get_payment_agents_by_name('Joe 2');
    is $result->@*, 1, 'One row is found';
    is $result->[0]->{client_loginid}, $pa_client_2->loginid, 'Client loginid is correct';

    $result = $pa->get_payment_agents_by_name('jOE 2');
    is $result->@*, 1, 'The search is case insensitive';
    is $result->[0]->{client_loginid}, $pa_client_2->loginid, 'Client loginid is correct';
};

subtest 'validate payment agent details' => sub {
    my $client1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client1->email('validate+' . $email);
    $client1->save;

    BOM::User->create(
        email    => $client1->email,
        password => 'test',
    )->add_client($client1);

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
                'payment_agent_name', 'url', 'information', 'supported_banks',
                'commission_deposit', 'commission_withdrawal', 'code_of_conduct_approval'
            )}
        },
        'Payment required fileds are returned';

    my %args = (
        'payment_agent_name'       => 'Nobody',
        'information'              => 'Request for pa application',
        'url'                      => 'http://abcd.com',
        'commission_withdrawal'    => 4,
        'commission_deposit'       => 5,
        'supported_banks'          => 'Visa,bank_transfer',
        'code_of_conduct_approval' => 0,
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

    for my $name (qw/payment_agent_name information supported_banks/) {
        for my $value ('_ -+,.', '_', '+', ',', '.') {
            is_deeply exception { $pa->validate_payment_agent_details(%args, $name => $value) },
                {
                'code'    => 'InvalidStringValue',
                'details' => {fields => [$name]}
                },
                "Expected failure for field: $name, value: <$value>";
        }
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

    my $min_max = BOM::Config::PaymentAgent::get_transfer_min_max('USD');

    set_absolute_time(1000);
    my $result = $pa->validate_payment_agent_details(%args);
    is_deeply $result,
        {
        'payment_agent_name'            => 'Nobody',
        'email'                         => $client1->email,
        'phone'                         => $client1->phone,
        'summary'                       => '',
        'information'                   => 'Request for pa application',
        'currency_code'                 => 'USD',
        'target_country'                => $client1->residence,
        'url'                           => 'http://abcd.com',
        'max_withdrawal'                => $min_max->{maximum},
        'min_withdrawal'                => $min_max->{minimum},
        'commission_deposit'            => 5,
        'commission_withdrawal'         => 4,
        'is_authenticated'              => 0,
        'is_listed'                     => 0,
        'supported_banks'               => 'Visa,bank_transfer',
        'code_of_conduct_approval'      => 1,
        'affiliate_id'                  => '',
        'code_of_conduct_approval_time' => 1000,
        },
        'Expected default values are returned - coc approval is set to current time';

    $result = $pa->validate_payment_agent_details(
        %args,
        payment_agent_name => " Nobody  ",
        supported_banks    => 'Visa ,  bank_transfer'
    );
    is_deeply $result,
        {
        'payment_agent_name'            => 'Nobody',
        'email'                         => $client1->email,
        'phone'                         => $client1->phone,
        'summary'                       => '',
        'information'                   => 'Request for pa application',
        'currency_code'                 => 'USD',
        'target_country'                => $client1->residence,
        'url'                           => 'http://abcd.com',
        'max_withdrawal'                => $min_max->{maximum},
        'min_withdrawal'                => $min_max->{minimum},
        'commission_deposit'            => 5,
        'commission_withdrawal'         => 4,
        'is_authenticated'              => 0,
        'is_listed'                     => 0,
        'supported_banks'               => 'Visa,bank_transfer',
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
        'phone'                         => '1234',
        'summary'                       => 'I am a test pa',
        'information'                   => 'Request for pa application',
        'currency_code'                 => 'EUR',
        'target_country'                => 'de',
        'url'                           => 'http://abcd.com',
        'commission_withdrawal'         => 4,
        'commission_deposit'            => 5,
        'max_withdrawal'                => 100,
        'commission_deposit'            => 1,
        'commission_withdrawal'         => 3,
        'min_withdrawal'                => 10,
        'is_authenticated'              => 1,
        'is_listed'                     => 1,
        'supported_banks'               => 'Visa,bank_transfer',
        'code_of_conduct_approval'      => 1,
        'affiliate_id'                  => '123abcd',
        'code_of_conduct_approval_time' => 1000
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

done_testing();
