use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;

subtest 'rule trading_account.should_match_landing_company' => sub {
    my $rule_name = 'trading_account.should_match_landing_company';

    subtest 'CR' => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
        });
        my $user = BOM::User->create(
            email    => 'test+cr@test.deriv',
            password => 'TRADING PASS',
        );
        $user->add_client($client);

        my $rule_engine = BOM::Rules::Engine->new(client => $client);

        my $params = {
            trading_platform_new_account => 1,
            account_type                 => 'demo',
            market_type                  => 'financial',
            password                     => 'C0rrect_p4ssword',
            platform                     => 'dxtrade',
        };

        ok $rule_engine->apply_rules($rule_name, $params), 'The test passes';

        # try to open a real trading account
        $params->{account_type} = 'real';

        is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
            {
            code           => 'RealAccountMissing',
            message_params => ['Deriv X']
            },
            'Real account missing';

        # give real account
        my $real = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        $user->add_client($real);
        ok $rule_engine->apply_rules($rule_name, $params), 'The test passes';

        # Complete gaming permutations
        $params->{market_type} = 'gaming';
        ok $rule_engine->apply_rules($rule_name, $params), 'The test passes';

        $params->{account_type} = 'demo';
        $params->{market_type}  = 'gaming';
        ok $rule_engine->apply_rules($rule_name, $params), 'The test passes';

        # Make the real client disabled and try to open a real account
        $params->{account_type} = 'real';
        $real->status->set('disabled', 'test', 'test');

        is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
            {
            code           => 'RealAccountMissing',
            message_params => ['Deriv X']
            },
            'Real account missing again';

        $real->status->clear_disabled;
        ok $rule_engine->apply_rules($rule_name, $params), 'The test passes again';

        # Make the real client duplicate_account and try to open a real account
        $real->status->set('duplicate_account', 'test', 'test');

        is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
            {
            code           => 'RealAccountMissing',
            message_params => ['Deriv X']
            },
            'Real account missing again';

        $real->status->clear_duplicate_account;
        ok $rule_engine->apply_rules($rule_name, $params), 'The test passes again';
    };

    subtest 'MX/MF' => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
            residence   => 'gb',
        });
        my $user = BOM::User->create(
            email    => 'test+gb@test.deriv',
            password => 'TRADING PASS',
        );
        $user->add_client($client);

        $client->residence('gb');
        $client->save;

        my $rule_engine = BOM::Rules::Engine->new(client => $client);

        my $params = {
            trading_platform_new_account => 1,
            account_type                 => 'demo',
            market_type                  => 'gaming',
            password                     => 'C0rrect_p4ssword',
            platform                     => 'dxtrade',
        };

        is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
            {
            code           => 'TradingAccountNotAllowed',
            message_params => ['Deriv X']
            },
            'not available for MX';

        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });

        $client->residence('at');
        $client->save;
        $rule_engine = BOM::Rules::Engine->new(client => $client);

        $user->add_client($client);

        is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
            {
            code           => 'TradingAccountNotAllowed',
            message_params => ['Deriv X']
            },
            'not available for MF';
    };

    subtest 'MLT/MF' => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MLT',
            residence   => 'at',
        });
        my $user = BOM::User->create(
            email    => 'test+mlt@test.deriv',
            password => 'TRADING PASS',
        );
        $user->add_client($client);

        $client->residence('at');
        $client->save;

        my $rule_engine = BOM::Rules::Engine->new(client => $client);

        my $params = {
            trading_platform_new_account => 1,
            account_type                 => 'demo',
            market_type                  => 'gaming',
            password                     => 'C0rrect_p4ssword',
            platform                     => 'dxtrade',
        };

        is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
            {
            code           => 'TradingAccountNotAllowed',
            message_params => ['Deriv X']
            },
            'not available for MLT';

        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });

        $client->residence('at');
        $client->save;
        $rule_engine = BOM::Rules::Engine->new(client => $client);

        $user->add_client($client);

        is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
            {
            code           => 'TradingAccountNotAllowed',
            message_params => ['Deriv X']
            },
            'not available for MF';
    };
};

subtest 'rule trading_account.should_be_age_verified' => sub {
    # Redidence do not require trading_age_verification
    my $residence      = 'br';
    my $country_config = Brands::Countries->new()->countries_list->{$residence};
    my $country_mock   = Test::MockModule->new('Brands::Countries');
    $country_mock->mock(
        'countries_list',
        sub {
            return {$residence => $country_config};
        });

    $country_config->{trading_age_verification} = 0;
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => $residence,
    });

    my $rule_name = 'trading_account.should_be_age_verified';

    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    ok $rule_engine->apply_rules($rule_name), 'Test passes as this residence does not need age verification';

    # Redidence needs age verification
    $residence                                  = 'gb';
    $country_config->{trading_age_verification} = 1;
    $client                                     = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
        residence   => $residence,
    });

    $rule_engine = BOM::Rules::Engine->new(client => $client);

    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {code => 'NoAgeVerification'}, 'Age verification required';

    $client->status->set('age_verification', 'test', 'test');

    ok $rule_engine->apply_rules($rule_name), 'Test passes as the account is age verified';

    # Redidence needs age verification + virtual account
    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        residence   => $residence,
    });
    my $user = BOM::User->create(
        email    => 'test+vr@test.deriv',
        password => 'TRADING PASS',
    );
    $user->add_client($client);

    $rule_engine = BOM::Rules::Engine->new(client => $client);

    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {code => 'RealAccountMissing'}, 'Real account missing';

    # Give real account
    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
        residence   => $residence,
    });
    $user->add_client($client);

    $rule_engine = BOM::Rules::Engine->new(client => $client);

    is_deeply exception { $rule_engine->apply_rules($rule_name) }, {code => 'NoAgeVerification'}, 'Age verification required';

    $client->status->set('age_verification', 'test', 'test');

    ok $rule_engine->apply_rules($rule_name), 'Test passes as the account is age verified';
};

subtest 'rule trading_account.should_complete_financial_assessment' => sub {
    my $rule_name = 'trading_account.should_complete_financial_assessment';
    my $mock      = Test::MockModule->new('BOM::User::Client');
    my $fa_complete;

    $mock->mock(
        'is_financial_assessment_complete',
        sub {
            $fa_complete;
        });

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'br',
    });

    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    # give some params
    my $params = {
        trading_platform_new_account => 1,
        account_type                 => 'real',
        market_type                  => 'gaming',
        password                     => 'C0rrect_p4ssword',
        platform                     => 'dxtrade',
    };

    # incomplete and required fa
    $fa_complete = 0;
    is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
        {
        code           => 'FinancialAssessmentMandatory',
        message_params => ['Deriv X']
        },
        'Financial Assesment mandatory';

    # complete fa
    $fa_complete = 1;
    ok $rule_engine->apply_rules($rule_name, $params), 'Financial Assessment completed';
};

subtest 'rule trading_account.should_provide_tax_details' => sub {
    my $rule_name = 'trading_account.should_provide_tax_details';

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'br',
    });

    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    # give some params
    my $params = {
        trading_platform_new_account => 1,
        account_type                 => 'real',
        market_type                  => 'gaming',
        password                     => 'C0rrect_p4ssword',
        platform                     => 'dxtrade',
    };

    #some mockery
    my $tax_information;
    my $crs_tin_information;
    my $is_tax_detail_mandatory;

    my $mock_lc = Test::MockModule->new('LandingCompany');
    $mock_lc->mock(
        'requirements',
        sub {
            return {
                compliance => {
                    tax_information => $tax_information,
                }};
        });
    my $mock_country = Test::MockModule->new('Brands::Countries');
    $mock_country->mock(
        'is_tax_detail_mandatory',
        sub {
            return $is_tax_detail_mandatory;
        });
    my $mock_status = Test::MockModule->new('BOM::User::Client::Status');
    $mock_status->mock(
        'crs_tin_information',
        sub {
            return $crs_tin_information;
        });

    my $cases = [{
            tax_information         => 0,
            crs_tin_information     => 0,
            is_tax_detail_mandatory => 0,
            result                  => 1,
        },
        {
            tax_information         => 0,
            crs_tin_information     => 0,
            is_tax_detail_mandatory => 1,
            result                  => 1,
        },
        {
            tax_information         => 0,
            crs_tin_information     => 1,
            is_tax_detail_mandatory => 1,
            result                  => 1,
        },
        {
            tax_information         => 1,
            crs_tin_information     => 1,
            is_tax_detail_mandatory => 1,
            result                  => 1,
        },
        {
            tax_information         => 1,
            crs_tin_information     => 1,
            is_tax_detail_mandatory => 0,
            result                  => 1,
        },
        {
            tax_information         => 1,
            crs_tin_information     => 0,
            is_tax_detail_mandatory => 0,
            result                  => 1,
        },
        {
            tax_information         => 1,
            crs_tin_information     => 0,
            is_tax_detail_mandatory => 1,
            result                  => 0,
        }];

    for my $case ($cases->@*) {
        $tax_information         = $case->{tax_information};
        $crs_tin_information     = $case->{crs_tin_information};
        $is_tax_detail_mandatory = $case->{is_tax_detail_mandatory};

        if ($case->{result}) {
            ok $rule_engine->apply_rules($rule_name, $params), 'Tax details not needed';
        } else {
            is_deeply exception { $rule_engine->apply_rules($rule_name, $params) },
                {
                code           => 'TINDetailsMandatory',
                message_params => ['Deriv X']
                },
                'Tax details are mandatory';
        }
    }

    $mock_lc->unmock_all;
    $mock_country->unmock_all;
    $mock_status->unmock_all;
};

subtest 'rule trading_account.client_should_be_real' => sub {
    my $rule_name = 'trading_account.client_should_be_real';

    my $vrtc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });

    my $rule_engine = BOM::Rules::Engine->new(client => $vrtc);
    is_deeply exception { $rule_engine->apply_rules($rule_name, {platform => 'dxtrade'}) },
        {
        code           => 'AccountShouldBeReal',
        message_params => ['Deriv X']
        },
        'expected error when passing virtual account';

    my $cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $rule_engine = BOM::Rules::Engine->new(client => $cr);
    ok $rule_engine->apply_rules($rule_name), 'Test passes with CR';
};

subtest 'rule trading_account.allowed_currency' => sub {
    my $rule_name = 'trading_account.allowed_currency';

    my $vrtc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });

    my $available_currencies = {
        svg => {
            dxtrade => [qw/USD/],
        }};

    my $lc_mock = Test::MockModule->new('LandingCompany');
    $lc_mock->mock(
        'available_trading_platform_currency_group',
        sub {
            my ($lc) = @_;
            $available_currencies->{$lc->short};
        });

    my $rule_engine = BOM::Rules::Engine->new(client => $vrtc);
    is_deeply exception { $rule_engine->apply_rules($rule_name, {platform => 'dxtrade', 'currency' => 'EUR'}) },
        {
        code           => 'TradingAccountCurrencyNotAllowed',
        message_params => ['Deriv X']
        },
        'EUR is not allowed';

    is_deeply exception { $rule_engine->apply_rules($rule_name, {platform => 'dxtrade', 'currency' => 'USD'}) },
        {
        code           => 'TradingAccountCurrencyNotAllowed',
        message_params => ['Deriv X']
        },
        'USD is not allowed (vrtc account)';

    $available_currencies->{virtual} = {
        dxtrade => [qw/USD/],
    };

    ok $rule_engine->apply_rules(
        $rule_name,
        {
            platform => 'dxtrade',
            currency => 'USD'
        }
        ),
        'Test passes with USD';

    $lc_mock->unmock_all;
};

done_testing();
