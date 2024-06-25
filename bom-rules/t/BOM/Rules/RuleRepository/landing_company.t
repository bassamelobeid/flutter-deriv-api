use strict;
use warnings;
no indirect;

use Test::Most;
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $user = BOM::User->create(
    email    => 'rules_lc@test.deriv',
    password => 'TEST PASS',
);
$user->add_client($client);
$user->add_client($client_vr);
$client->user($user);
$client_vr->user($user);
$client->save;
$client_vr->save;

my $rule_engine = BOM::Rules::Engine->new(
    client => $client,
    user   => $user
);
my $rule_engine_vr = BOM::Rules::Engine->new(
    client => $client_vr,
    user   => $user
);

# Keeping this one test with MLT (to check for no validation when MLT is removed from client ymls)
subtest 'rule landing_company.accounts_limit_not_reached' => sub {
    my $rule_name = 'landing_company.accounts_limit_not_reached';

    like exception { $rule_engine->apply_rules($rule_name) }, qr/landing_company is required/, 'Fails without landing company';
    my %args = (
        landing_company => 'malta',
        account_type    => 'binary'
    );
    like exception { $rule_engine->apply_rules($rule_name, %args) }, qr/Client loginid is missing/, 'Fails without client loginid';
    $args{loginid} = $client->loginid;
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'There is no malta account so it is ok';

    my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
    });
    $user->add_client($client_mlt);
    $client_mlt->binary_user_id($user->id);
    $client_mlt->save;

    delete $user->{landing_companies};

    my $engine = BOM::Rules::Engine->new(
        client => $client_mlt,
        user   => $user
    );

    $args{loginid} = $client_mlt->loginid;
    is_deeply exception { $engine->apply_rules($rule_name, %args) },
        {
        error_code  => 'NewAccountLimitReached',
        rule        => $rule_name,
        description => 'New account limit reached'
        },
        'Number of MLT accounts is limited';

    delete $user->{landing_companies};

    $args{landing_company} = 'maltainvest';
    lives_ok { $engine->apply_rules($rule_name, %args) } 'There is no maltainvest account so it is ok';

    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    $args{loginid} = $client_mf->loginid;
    $user->add_client($client_mf);
    $user->add_client($client_vr);
    $engine = BOM::Rules::Engine->new(
        client => [$client_mf, $client_mlt, $client_vr],
        user   => $user
    );

    delete $user->{landing_companies};

    is_deeply exception { $engine->apply_rules($rule_name, %args) },
        {
        error_code  => 'FinancialAccountExists',
        rule        => $rule_name,
        description => 'Financial account limit reached'
        },
        'Number of MF accounts is limited';

    $args{account_type} = 'wallet';
    lives_ok { $engine->apply_rules($rule_name, %args) } 'Wallet accounts is not restricted by trading accounts';

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(is_wallet => sub { 1 });
    lives_ok { $engine->apply_rules($rule_name, %args) } 'Wallet accounts is not restricted';
    $mock_client->unmock_all;

    $args{account_type} = 'standart';
    $client_mf->status->set('duplicate_account', 'test', 'test');
    lives_ok { $engine->apply_rules($rule_name, %args) } 'Duplicate accounts are ignored';
    $client_mf->status->clear_duplicate_account;

    $client_mf->status->set('disabled', 'test', 'test');
    is_deeply exception { $engine->apply_rules($rule_name, %args) }, undef,
        'No limits for new flow, trading account  should be only limited by wallets';

    subtest 'virtual wallets' => sub {
        my $user = BOM::User->create(
            email    => 'wallet@test.com',
            password => 'x',
        );

        my $vrw = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRW', account_type => 'virtual'});
        $user->add_client($vrw);
        my $engine = BOM::Rules::Engine->new(
            client => $vrw,
            user   => $user
        );

        my %args = (
            loginid         => $vrw->loginid,
            wallet_loginid  => $vrw->loginid,
            account_type    => 'standard',
            landing_company => 'virtual'
        );
        is exception { $engine->apply_rules($rule_name, %args) }, undef, 'linked VRTC is allowed';

        my $vrtc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRTC', account_type => 'standard'});
        $user->add_client($vrtc, $vrw->loginid);

        delete $user->{landing_companies};

        is_deeply exception { $engine->apply_rules($rule_name, %args) },
            {
            error_code  => 'VirtualAccountExists',
            rule        => $rule_name,
            description => 'Virtual account limit reached'
            },
            'Number of VRTC accounts is limited';
    };

};

subtest 'rule landing_company.required_fields_are_non_empty' => sub {
    my $rule_name = 'landing_company.required_fields_are_non_empty';

    my %args = (
        loginid    => $client->loginid,
        first_name => '',
        last_name  => ''
    );

    my $mock_lc = Test::MockModule->new('Business::Config::LandingCompany');
    $mock_lc->redefine(requirements => sub { return +{signup => [qw(first_name last_name)]}; });

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code  => 'InsufficientAccountDetails',
        details     => {missing => [qw(first_name last_name)]},
        rule        => $rule_name,
        description => 'first_name, last_name required field(s) missing'
        },
        'Error with missing client data';

    is_deeply exception { $rule_engine_vr->apply_rules($rule_name, %args, loginid => $client_vr->loginid) },
        {
        error_code  => 'InsufficientAccountDetails',
        details     => {missing => [qw(first_name last_name)]},
        rule        => $rule_name,
        description => 'first_name, last_name required field(s) missing'
        },
        'Error with missing client data (vr)';

    %args = (
        loginid => $client_vr->loginid,
    );

    my $client_mock = Test::MockModule->new(ref($client_vr));
    my $names       = {
        $client_vr->{loginid} => {
            first_name => undef,
            last_name  => undef,
        },
        $client->{loginid} => {
            first_name => undef,
            last_name  => undef,
        },
    };

    $client_mock->mock(
        'duplicate_sibling_from_vr',
        sub {
            return $client;
        });

    $client_mock->mock(
        'first_name',
        sub {
            my ($self) = @_;

            return $names->{$self->loginid}->{first_name};
        });

    $client_mock->mock(
        'last_name',
        sub {
            my ($self) = @_;

            return $names->{$self->loginid}->{last_name};
        });

    %args = (
        loginid => $client_vr->loginid,
    );

    is_deeply exception { $rule_engine_vr->apply_rules($rule_name, %args) },
        {
        error_code  => 'InsufficientAccountDetails',
        details     => {missing => [qw(first_name last_name)]},
        rule        => $rule_name,
        description => 'first_name, last_name required field(s) missing'
        },
        'Error with missing client data (vr)';

    $client->status->setnx('duplicate_account', 'test', 'test');

    $names = {
        $client_vr->{loginid} => {
            first_name => undef,
            last_name  => undef,
        },
        $client->{loginid} => {
            first_name => 'BRAD',
            last_name  => 'PITT',
        },
    };

    lives_ok { $rule_engine_vr->apply_rules($rule_name, %args) } 'Test passes when client has the data';

    %args = (
        loginid    => $client->loginid,
        first_name => 'Master',
        last_name  => 'Mind'
    );
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes when client has the data';

    $mock_lc->redefine(is_for_affiliates => sub { return 1; });

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code  => 'InsufficientAccountDetails',
        details     => {missing => [qw(affiliate_plan)]},
        rule        => $rule_name,
        description => 'affiliate_plan required field(s) missing'
        },
        'Error with missing client data';

    $args{affiliate_plan} = 'turnover';
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes when client has the data';

    $mock_lc->redefine(requirements => sub { return +{signup => [qw(tax_identification_number)]}; });

    $client->tax_identification_number(undef);
    $client->tin_approved_time(undef);
    $client->save;

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code  => 'InsufficientAccountDetails',
        details     => {missing => [qw(tax_identification_number)]},
        rule        => $rule_name,
        description => 'tax_identification_number required field(s) missing',
        },
        'Error when tax_identification_number is missing and client does not have a manually approved TIN';

    $client->tin_approved_time(Date::Utility->new()->datetime_yyyymmdd_hhmmss);
    $client->save;

    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes when client has a manually approved TIN';

    $mock_lc->unmock_all;
    $client_mock->unmock_all;
};

subtest 'rule landing_company.currency_is_allowed' => sub {
    my $rule_name = 'landing_company.currency_is_allowed';

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Either landing_company or loginid is required/, 'Landing company is required';
    my %args = (landing_company => 'svg');

    like exception { $rule_engine->apply_rules($rule_name, %args) }, qr/Client loginid is missing/, 'Landing company is required';
    $args{loginid} = $client->loginid;

    my $mock_lc = Test::MockModule->new('Business::Config::LandingCompany');
    $mock_lc->redefine(legal_allowed_currencies => sub { return {} });
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Succeeds with no currency - even when all currencies are illegal';

    $args{currency} = 'USD';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code  => 'CurrencyNotApplicable',
        params      => 'USD',
        rule        => $rule_name,
        description => "Currency $args{currency} not allowed"
        },
        'Error for illegal currency';

    $mock_lc->redefine(
        legal_allowed_currencies => sub {
            return {
                USD => {
                    name => 'U.S. Dollar',
                    type => 'fiat',
                },
            };
        });
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'The currency is legal now';

    $mock_lc->unmock_all;
};

subtest 'rule landing_company.p2p_availability' => sub {
    my $rule_name = 'landing_company.p2p_availability';

    my $mock_lc = Test::MockModule->new('Business::Config::LandingCompany');
    $mock_lc->redefine(p2p_available => sub { return 1 });

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Either landing_company or loginid is required/, 'Landing company is required';
    my %args = (landing_company => 'svg');
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Empty args are accepted';
    $args{account_opening_reason} = 'p2p';
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'It always passes if p2p is available';

    $mock_lc->redefine(p2p_available => sub { return 0 });
    $args{account_opening_reason} = 'dummy';
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'any p2p unrelated reason is fine';

    $args{account_opening_reason} = 'p2p exchange';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code  => 'P2PRestrictedCountry',
        rule        => 'landing_company.p2p_availability',
        description => 'P2P is currently unavailable for the selected landing company'
        },
        'It fails for a p2p related reason in args';

    $args{account_opening_reason} = 'Peer-to-peer exchange';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code  => 'P2PRestrictedCountry',
        rule        => 'landing_company.p2p_availability',
        description => 'P2P is currently unavailable for the selected landing company'
        },
        "It fails when reason is 'Peer-to-peer exchange'";

    $mock_lc->unmock_all;
};

done_testing();
