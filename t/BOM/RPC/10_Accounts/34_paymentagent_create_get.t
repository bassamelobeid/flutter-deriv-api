use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw(invalidate_object_cache);
use BOM::Test::RPC::QueueClient;
use BOM::Test::Email;
use BOM::Platform::Context qw (request);
use BOM::Config::Runtime;
use BOM::User;

my $c = BOM::Test::RPC::QueueClient->new();

my $app_config  = BOM::Config::Runtime->instance->app_config;
my $mock_client = Test::MockModule->new('BOM::User::Client');

my $user_vr = BOM::User->create(
    email    => 'vr@test.com',
    password => 'x'
);
my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'VRTC',
    email          => $user_vr->email,
    binary_user_id => $user_vr->id,
});
$user_vr->add_client($client_vr);

my ($token_vr) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_vr->loginid);

my $user_mf = BOM::User->create(
    email    => 'mf@test.com',
    password => 'x'
);
my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'MF',
    email          => $user_mf->email,
    binary_user_id => $user_mf->id,
});
$user_mf->add_client($client_mf);
my ($token_mf) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_mf->loginid);

my $user_cr = BOM::User->create(
    email    => 'cr@test.com',
    password => 'x'
);
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $user_cr->email,
    binary_user_id => $user_cr->id,
});
$user_cr->add_client($client_cr);
my ($token_cr) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_cr->loginid);

# Used it to enable wallet migration in progress
sub _enable_wallet_migration {
    my $user       = shift;
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->system->suspend->wallets(0);
    my $redis_rw = BOM::Config::Redis::redis_replicated_write();
    $redis_rw->set(
        "WALLET::MIGRATION::IN_PROGRESS::" . $user->id, 1,
        EX => 30 * 60,
        "NX"
    );
}
# Used it to disable wallet migration
sub _disable_wallet_migration {
    my $user       = shift;
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->system->suspend->wallets(1);
    my $redis_rw = BOM::Config::Redis::redis_replicated_write();
    $redis_rw->del("WALLET::MIGRATION::IN_PROGRESS::" . $user->id);
}

subtest 'Eligibility' => sub {

    my $params = {
        language => 'EN',
        token    => $token_vr,
    };

    $c->call_ok('paymentagent_create', $params)
        ->has_error->error_code_is('PermissionDenied', 'VR client gets error code PermissionDenied from paymentagent_create');

    cmp_deeply(
        $c->call_ok('paymentagent_details', $params)->has_no_error->result,
        {
            stash     => ignore(),
            can_apply => 0,
        },
        'VR client gets can_apply=0 from paymentagent_details'
    );

    $params->{token} = $token_mf;

    $c->call_ok('paymentagent_create', $params)
        ->has_error->error_code_is('PaymentAgentNotAvailable', 'MF client gets error code PaymentAgentNotAvailable from paymentagent_create');

    cmp_deeply(
        $c->call_ok('paymentagent_details', $params)->has_no_error->result,
        {
            stash     => ignore(),
            can_apply => 0,
        },
        'MF client gets can_apply=0 from paymentagent_details'
    );

    $params->{token} = $token_cr;

    $c->call_ok('paymentagent_create', $params)
        ->has_error->error_code_is('SetExistingAccountCurrency',
        'CR account with no currency gets error code NoAccountCurrency from paymentagent_create');

    cmp_deeply(
        $c->call_ok('paymentagent_details', $params)->has_no_error->result,
        {
            stash     => ignore(),
            can_apply => 0,
        },
        'CR account with no currency gets can_apply=0 from paymentagent_details'
    );

    $client_cr->set_default_account('USD');

    $c->call_ok('paymentagent_create', $params)
        ->has_error->error_code_is('NotAgeVerified', 'CR client with no POI and no POA gets error code NotAuthenticated from paymentagent_create');

    cmp_deeply(
        $c->call_ok('paymentagent_details', $params)->has_no_error->result,
        {
            stash                 => ignore(),
            can_apply             => 0,
            eligibilty_validation => bag('NotAuthenticated', 'NotAgeVerified'),
        },
        'CR client with no POI and no POA gets can_apply=0 from paymentagent_details'
    );

    $client_cr->status->set('age_verification', 'x', 'x');

    $c->call_ok('paymentagent_create', $params)
        ->has_error->error_code_is('NotAuthenticated', 'CR client with no POA gets error code NotAuthenticated from paymentagent_create');

    cmp_deeply(
        $c->call_ok('paymentagent_details', $params)->has_no_error->result,
        {
            stash                 => ignore(),
            can_apply             => 0,
            eligibilty_validation => ['NotAuthenticated'],
        },
        'CR client with no POA gets can_apply=0 from paymentagent_details'
    );

    $mock_client->redefine(fully_authenticated => 1);

    $client_cr->status->set('unwelcome', 'x', 'x');

    $c->call_ok('paymentagent_create', $params)->has_error->error_code_is('PaymentAgentClientStatusNotEligible',
        'unwelcome CR client gets error code PaymentAgentClientStatusNotEligible from paymentagent_create');

    cmp_deeply(
        $c->call_ok('paymentagent_details', $params)->has_no_error->result,
        {
            stash                 => ignore(),
            can_apply             => 0,
            eligibilty_validation => ['PaymentAgentClientStatusNotEligible'],
        },
        'unwelcome CR client gets can_apply=0 from paymentagent_details'
    );

    $client_cr->status->clear_unwelcome;

    $app_config->payment_agents->initial_deposit_per_country('{ "default": 100 }');

    $c->call_ok('paymentagent_create', $params)->has_error->error_code_is('PaymentAgentInsufficientDeposit',
        'CR client with insufficient deposit gets error code PaymentAgentInsufficientDeposit from paymentagent_create');

    cmp_deeply(
        $c->call_ok('paymentagent_details', $params)->has_no_error->result,
        {
            stash                 => ignore(),
            can_apply             => 0,
            eligibilty_validation => ['PaymentAgentInsufficientDeposit'],
        },
        'CR client with insufficient deposit gets can_apply=0 from paymentagent_details'
    );

    $app_config->payment_agents->initial_deposit_per_country('{}');

    cmp_deeply(
        $c->call_ok('paymentagent_details', $params)->has_no_error->result,
        {
            stash     => ignore(),
            can_apply => 1,
        },
        'Authenticated CR account gets can_apply=1 from paymentagent_details'
    );
};

subtest 'Input validations' => sub {

    my $params = {
        language => 'EN',
        token    => $token_cr,
    };

    cmp_deeply $c->call_ok('paymentagent_create', $params)->has_error->result->{error},
        {
        code              => 'InputValidationFailed',
        message_to_client => 'This field is required.',
        details           => {
            fields => bag(
                'supported_payment_methods', 'information',        'payment_agent_name', 'urls',
                'code_of_conduct_approval',  'commission_deposit', 'commission_withdrawal'
            )}
        },
        'required fields cannot be empty';

    $params->{args} = {
        'payment_agent_name'        => '+_',
        'information'               => '   ',
        'urls'                      => [{url => ' &^% '}],
        'commission_withdrawal'     => 'abcd',
        'commission_deposit'        => 'abcd',
        'supported_payment_methods' => [{payment_method => '   '}, {payment_method => 'bank_transfer'}],
        'code_of_conduct_approval'  => 0,
    };

    is_deeply $c->call_ok('paymentagent_create', $params)->has_error->result->{error},
        {
        code              => 'InputValidationFailed',
        message_to_client => 'Code of conduct should be accepted.',
        details           => {fields => ['code_of_conduct_approval']}
        },
        'COC approval is required';

    $params->{args}{code_of_conduct_approval} = 1;

    cmp_deeply $c->call_ok('paymentagent_create', $params)->has_error->result->{error},
        {
        code              => 'InputValidationFailed',
        message_to_client => 'This field must contain at least one alphabetic character.',
        details           => {fields => bag('payment_agent_name', 'information', 'supported_payment_methods', 'urls')}
        },
        'String values must contain at least one alphabetic character';

    $params->{args}{$_}                        = 'Valid String' for (qw/payment_agent_name information/);
    $params->{args}{urls}                      = [{url            => 'https://www.pa.com'}];
    $params->{args}{supported_payment_methods} = [{payment_method => 'Valid method'}];

    cmp_deeply $c->call_ok('paymentagent_create', $params)->has_error->result->{error},
        {
        code              => 'InputValidationFailed',
        message_to_client => 'The numeric value is invalid.',
        details           => {fields => bag('commission_withdrawal', 'commission_deposit')}
        },
        'Commission must be a valid number.';

    $params->{args}{commission_withdrawal} = -1;
    $params->{args}{commission_deposit}    = 4.0001;

    cmp_deeply $c->call_ok('paymentagent_create', $params)->has_error->result->{error},
        {
        code              => 'InputValidationFailed',
        message_to_client => 'It must be between 0 and 9.',
        details           => {fields => bag('commission_withdrawal')}
        },
        'Commissions should be in range';

    $params->{args}{commission_withdrawal} = 1;

    cmp_deeply $c->call_ok('paymentagent_create', $params)->has_error->result->{error},
        {
        code              => 'InputValidationFailed',
        message_to_client => 'Only 2 decimal places are allowed.',
        details           => {fields => bag('commission_deposit')}
        },
        'Commission decimal precision is 2';
    $params->{args}->{commission_deposit} = 1;
};

subtest 'Application for PA' => sub {

    is $client_cr->get_payment_agent, undef, 'Client does not have any payment agent yet';

    my $params = {
        language => 'EN',
        token    => $token_cr,
        args     => {
            'payment_agent_name'        => 'Nobody',
            'information'               => 'Request for pa application',
            'urls'                      => [{url => 'http://abcd.com'}],
            'commission_withdrawal'     => 4,
            'commission_deposit'        => 5,
            'supported_payment_methods' => [map { +{payment_method => $_} } qw/Visa bank_transfer/],
            'code_of_conduct_approval'  => 1,
        },
    };

    _enable_wallet_migration($client_cr->user);
    $c->call_ok('paymentagent_create', $params)
        ->has_no_system_error->has_error->error_code_is('WalletMigrationInprogress', 'The wallet migration is in progress.')
        ->error_message_is(
        'This may take up to 2 minutes. During this time, you will not be able to deposit, withdraw, transfer, and add new accounts.');
    _disable_wallet_migration($client_cr->user);

    mailbox_clear();

    $c->call_ok('paymentagent_create', $params)->has_no_system_error->has_no_error('paymentagent_create is called successfully');

    my $min_max         = BOM::Config::PaymentAgent::get_transfer_min_max('USD');
    my %expected_values = (
        'payment_agent_name'        => 'Nobody',
        'urls'                      => [{url => 'http://abcd.com'}],
        'email'                     => $client_cr->email,
        'phone_numbers'             => [{phone_number => $client_cr->phone}],
        'information'               => 'Request for pa application',
        'currency_code'             => 'USD',
        'target_country'            => $client_cr->residence,
        'max_withdrawal'            => $min_max->{maximum},
        'min_withdrawal'            => $min_max->{minimum},
        'commission_deposit'        => 5,
        'commission_withdrawal'     => 4,
        'code_of_conduct_approval'  => 1,
        'affiliate_id'              => '',
        'supported_payment_methods' => [map { +{payment_method => $_} } qw/bank_transfer Visa/],
        'newly_authorized'          => 0,
    );

    cmp_deeply(
        $c->call_ok('paymentagent_details', $params)->has_no_system_error->has_no_error->result,
        {
            %expected_values,
            status    => 'applied',
            can_apply => 0,
            stash     => ignore(),
        },
        'paymentagent_details for applied pa'
    );

    invalidate_object_cache($client_cr);
    ok my $pa = $client_cr->get_payment_agent, 'Client has a payment agent now';
    is_deeply {
        map { $_ => $pa->$_ } keys %expected_values
    }, \%expected_values, 'PA details are correct';

    ok $pa->last_application_time, 'application time was set';
    is $pa->application_attempts, 1, 'application attempts is 1';

    my $email = mailbox_search(subject => 'Payment agent application submitted by ' . $client_cr->loginid);
    ok $email, 'An email is sent';

    my $brand = request->brand;
    is $email->{from},    $brand->emails('system'),      'email sender is correct';
    is $email->{to}->[0], $brand->emails('pa_livechat'), 'email receiver is correct';

    for my $key (keys %expected_values) {
        next if $key =~ /^(status|newly_authorized)$/;
        my $val = $expected_values{$key};
        if (ref $val eq 'ARRAY') {
            my $field = $pa->details_main_field->{$key};
            $val = join(',', sort map { $_->{$field} } @$val);
        }
        like $email->{body}, qr/$key: \Q$val/, "The field $key is included in the email body";
    }

    $c->call_ok('paymentagent_create', $params)
        ->has_error->error_code_is('PaymentAgentAlreadyApplied',
        'PA with status applied gets error code PaymentAgentAlreadyApplied from paymentagent_create');

    $pa->status('authorized');
    $pa->save;

    $c->call_ok('paymentagent_create', $params)
        ->has_error->error_code_is('PaymentAgentAlreadyExists',
        'PA with status authorized gets error code PaymentAgentAlreadyExists from paymentagent_create');

    cmp_deeply(
        $c->call_ok('paymentagent_details', $params)->has_no_system_error->has_no_error->result,
        {
            %expected_values,
            status    => 'authorized',
            can_apply => 0,
            stash     => ignore(),
        },
        'paymentagent_details for authorized pa'
    );

    $pa->status('suspended');
    $pa->save;

    $c->call_ok('paymentagent_create', $params)->has_error->error_code_is('PaymentAgentStatusNotEligible',
        'PA with status suspended gets error code PaymentAgentStatusNotEligible from paymentagent_create');

    cmp_deeply(
        $c->call_ok('paymentagent_details', $params)->has_no_system_error->has_no_error->result,
        {
            %expected_values,
            status    => 'suspended',
            can_apply => 0,
            stash     => ignore(),
        },
        'paymentagent_details for suspended pa'
    );

    $pa->status('rejected');
    $pa->save;

    cmp_deeply(
        $c->call_ok('paymentagent_details', $params)->has_no_system_error->has_no_error->result,
        {
            %expected_values,
            status    => 'rejected',
            can_apply => 1,
            stash     => ignore(),
        },
        'paymentagent_details for rejected pa'
    );

    $c->call_ok('paymentagent_create', $params)->has_no_system_error->has_no_error('PA with status rejected can reapply');

    invalidate_object_cache($client_cr);
    $pa = $client_cr->get_payment_agent;

    is $pa->application_attempts, 2,         'application attempts is now 2';
    is $pa->status,               'applied', 'status is now applied';
};

done_testing();
