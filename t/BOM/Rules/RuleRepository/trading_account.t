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
            residence   => 'au',
        });
        my $user = BOM::User->create(
            email    => 'test+cr@test.deriv',
            password => 'TRADING PASS',
        );
        $user->add_client($client);

        my $rule_engine = BOM::Rules::Engine->new(client => $client);

        my $params = {
            trading_platform_new_account => 1,
            loginid                      => $client->loginid,
            account_type                 => 'demo',
            market_type                  => 'all',
            password                     => 'C0rrect_p4ssword',
            platform                     => 'dxtrade',
        };

        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
            {
            error_code => 'TradingAccountNotAllowed',
            params     => ['Deriv X'],
            rule       => $rule_name
            },
            'Australia not allowed';

        $client->residence('id');
        $client->save;
        ok $rule_engine->apply_rules($rule_name, %$params), 'The test passes';

        # try to open a real trading account
        $params->{account_type} = 'real';

        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
            {
            error_code => 'RealAccountMissing',
            params     => ['Deriv X'],
            rule       => $rule_name
            },
            'Real account missing';

        # give real account
        my $real = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        $user->add_client($real);
        $rule_engine = BOM::Rules::Engine->new(client => $real);
        $params->{loginid} = $real->loginid;
        ok $rule_engine->apply_rules($rule_name, %$params), 'The test passes';

        $real->residence('jp');
        $real->save;

        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
            {
            error_code => 'TradingAccountNotAllowed',
            params     => ['Deriv X'],
            rule       => $rule_name
            },
            'Japan cannot open financial demo';

        # Make the real client disabled and try to open a real account
        $params->{account_type} = 'real';

        # Make the real client duplicate_account and try to open a real account
        $params->{market_type} = 'all';
        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
            {
            error_code => 'TradingAccountNotAllowed',
            params     => ['Deriv X'],
            rule       => $rule_name
            },
            'Japan cannot open financial real';

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
            loginid                      => $client->loginid,
            account_type                 => 'demo',
            market_type                  => 'all',
            password                     => 'C0rrect_p4ssword',
            platform                     => 'dxtrade',
        };

        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
            {
            error_code => 'TradingAccountNotAllowed',
            params     => ['Deriv X'],
            rule       => $rule_name
            },
            'not available for MX';

        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });

        $client->residence('at');
        $client->save;

        $user->add_client($client);

        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
            {
            error_code => 'TradingAccountNotAllowed',
            params     => ['Deriv X'],
            rule       => $rule_name
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
            loginid                      => $client->loginid,
            account_type                 => 'demo',
            market_type                  => 'all',
            password                     => 'C0rrect_p4ssword',
            platform                     => 'dxtrade',
        };

        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
            {
            error_code => 'TradingAccountNotAllowed',
            params     => ['Deriv X'],
            rule       => $rule_name
            },
            'not available for MLT';

        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });

        $client->residence('at');
        $client->save;

        $user->add_client($client);

        $rule_engine = BOM::Rules::Engine->new(client => $client);
        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params, loginid => $client->loginid) },
            {
            error_code => 'TradingAccountNotAllowed',
            params     => ['Deriv X'],
            rule       => $rule_name
            },
            'not available for MF';
    };
};

subtest 'rule trading_account.should_match_landing_company ctrader' => sub {
    my $rule_name = 'trading_account.should_match_landing_company';

    subtest 'CR' => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
            residence   => 'au',
        });
        my $user = BOM::User->create(
            email    => 'test+cr+ct@test.deriv',
            password => 'TRADING PASS',
        );
        $user->add_client($client);

        my $rule_engine = BOM::Rules::Engine->new(client => $client);

        my $params = {
            trading_platform_new_account => 1,
            loginid                      => $client->loginid,
            account_type                 => 'demo',
            market_type                  => 'all',
            password                     => 'C0rrect_p4ssword',
            platform                     => 'ctrader',
        };

        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
            {
            error_code => 'TradingAccountNotAllowed',
            params     => ['cTrader'],
            rule       => $rule_name
            },
            'Australia not allowed';

        $client->residence('id');
        $client->save;
        ok $rule_engine->apply_rules($rule_name, %$params), 'The test passes';

        # try to open a real trading account
        $params->{account_type} = 'real';

        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
            {
            error_code => 'RealAccountMissing',
            params     => ['cTrader'],
            rule       => $rule_name
            },
            'Real account missing';

        # give real account
        my $real = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        $user->add_client($real);
        $rule_engine = BOM::Rules::Engine->new(client => $real);
        $params->{loginid} = $real->loginid;
        ok $rule_engine->apply_rules($rule_name, %$params), 'The test passes';

        $real->residence('jp');
        $real->save;

        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
            {
            error_code => 'TradingAccountNotAllowed',
            params     => ['cTrader'],
            rule       => $rule_name
            },
            'Japan cannot open financial demo';

        # Make the real client disabled and try to open a real account
        $params->{account_type} = 'real';

        # Make the real client duplicate_account and try to open a real account
        $params->{market_type} = 'all';
        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
            {
            error_code => 'TradingAccountNotAllowed',
            params     => ['cTrader'],
            rule       => $rule_name
            },
            'Japan cannot open financial real';

    };

    subtest 'MX/MF' => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
            residence   => 'gb',
        });
        my $user = BOM::User->create(
            email    => 'test+gb+ct@test.deriv',
            password => 'TRADING PASS',
        );
        $user->add_client($client);

        $client->residence('gb');
        $client->save;

        my $rule_engine = BOM::Rules::Engine->new(client => $client);

        my $params = {
            trading_platform_new_account => 1,
            loginid                      => $client->loginid,
            account_type                 => 'demo',
            market_type                  => 'all',
            password                     => 'C0rrect_p4ssword',
            platform                     => 'ctrader',
        };

        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
            {
            error_code => 'TradingAccountNotAllowed',
            params     => ['cTrader'],
            rule       => $rule_name
            },
            'not available for MX';

        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });

        $client->residence('at');
        $client->save;

        $user->add_client($client);

        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
            {
            error_code => 'TradingAccountNotAllowed',
            params     => ['cTrader'],
            rule       => $rule_name
            },
            'not available for MF';
    };

    subtest 'MLT/MF' => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MLT',
            residence   => 'at',
        });
        my $user = BOM::User->create(
            email    => 'test+mlt+ct@test.deriv',
            password => 'TRADING PASS',
        );
        $user->add_client($client);

        $client->residence('at');
        $client->save;
        my $rule_engine = BOM::Rules::Engine->new(client => $client);

        my $params = {
            trading_platform_new_account => 1,
            loginid                      => $client->loginid,
            account_type                 => 'demo',
            market_type                  => 'all',
            password                     => 'C0rrect_p4ssword',
            platform                     => 'ctrader',
        };

        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
            {
            error_code => 'TradingAccountNotAllowed',
            params     => ['cTrader'],
            rule       => $rule_name
            },
            'not available for MLT';

        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });

        $client->residence('at');
        $client->save;

        $user->add_client($client);

        $rule_engine = BOM::Rules::Engine->new(client => $client);
        is_deeply exception { $rule_engine->apply_rules($rule_name, %$params, loginid => $client->loginid) },
            {
            error_code => 'TradingAccountNotAllowed',
            params     => ['cTrader'],
            rule       => $rule_name
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

    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my $rule_name = 'trading_account.should_be_age_verified';

    my $args = {loginid => $client->loginid};

    ok $rule_engine->apply_rules($rule_name, %$args), 'Test passes as this residence does not need age verification';
    # Redidence needs age verification
    $residence = 'gb';
    $country_config->{trading_age_verification} = 1;

    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
        residence   => $residence,
    });
    $rule_engine = BOM::Rules::Engine->new(client => $client);
    $args->{loginid} = $client->loginid;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'NoAgeVerification',
        rule       => $rule_name
        },
        'Age verification required';

    $client->status->set('age_verification', 'test', 'test');

    ok $rule_engine->apply_rules($rule_name, %$args), 'Test passes as the account is age verified';

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
    $args->{loginid} = $client->loginid;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'RealAccountMissing',
        rule       => $rule_name
        },
        'Real account missing';

    # Give real account
    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
        residence   => $residence,
    });
    $user->add_client($client);
    $rule_engine = BOM::Rules::Engine->new(client => $client);
    $args->{loginid} = $client->loginid;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'NoAgeVerification',
        rule       => $rule_name
        },
        'Age verification required';

    $client->status->set('age_verification', 'test', 'test');

    ok $rule_engine->apply_rules($rule_name, %$args), 'Test passes as the account is age verified';
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
        loginid                      => $client->loginid,
        account_type                 => 'real',
        market_type                  => 'all',
        password                     => 'C0rrect_p4ssword',
        platform                     => 'dxtrade',
    };

    # incomplete and required fa
    $fa_complete = 0;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
        {
        error_code => 'FinancialAssessmentMandatory',
        params     => ['Deriv X'],
        rule       => $rule_name
        },
        'Financial Assesment mandatory';

    # complete fa
    $fa_complete = 1;
    ok $rule_engine->apply_rules($rule_name, %$params), 'Financial Assessment completed';
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
        loginid                      => $client->loginid,
        account_type                 => 'real',
        market_type                  => 'all',
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
            ok $rule_engine->apply_rules($rule_name, %$params), 'Tax details not needed';
        } else {
            is_deeply exception { $rule_engine->apply_rules($rule_name, %$params) },
                {
                error_code => 'TINDetailsMandatory',
                params     => ['Deriv X'],
                rule       => $rule_name
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

    is_deeply exception { $rule_engine->apply_rules($rule_name, loginid => $vrtc->loginid, platform => 'dxtrade') },
        {
        error_code => 'AccountShouldBeReal',
        params     => ['Deriv X'],
        rule       => $rule_name
        },
        'expected error when passing virtual account';

    my $cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $rule_engine = BOM::Rules::Engine->new(client => $cr);
    ok $rule_engine->apply_rules($rule_name, loginid => $cr->loginid), 'Test passes with CR';
};

subtest 'rule trading_account.client_should_be_legacy_or_virtual_wallet' => sub {
    my $rule_name = 'trading_account.client_should_be_legacy_or_virtual_wallet';

    my $vrtc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });

    my $rule_engine = BOM::Rules::Engine->new(client => $vrtc);

    ok $rule_engine->apply_rules($rule_name, loginid => $vrtc->loginid), 'Test passes with VR';

    my $cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $rule_engine = BOM::Rules::Engine->new(client => $cr);
    ok $rule_engine->apply_rules($rule_name, loginid => $cr->loginid), 'Test passes with CR';

    my $crw = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CRW',
    });

    $rule_engine = BOM::Rules::Engine->new(client => $crw);
    is_deeply exception { $rule_engine->apply_rules($rule_name, loginid => $crw->loginid) },
        {
        error_code => 'TradingPlatformInvalidAccount',
        rule       => $rule_name
        },
        'expected error when passing wallet account';

    my $crt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code  => 'CR',
        account_type => 'standard'
    });

    $rule_engine = BOM::Rules::Engine->new(client => $crt);
    is_deeply exception { $rule_engine->apply_rules($rule_name, loginid => $crt->loginid) },
        {
        error_code => 'TradingPlatformInvalidAccount',
        rule       => $rule_name
        },
        'expected error when passing wallet account';

};

subtest 'rule trading_account.allowed_currency' => sub {
    my $rule_name = 'trading_account.allowed_currency';

    my $vrtc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });

    my $rule_engine = BOM::Rules::Engine->new(client => $vrtc);

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

    my $args = {
        loginid    => $vrtc->loginid,
        platform   => 'dxtrade',
        'currency' => 'EUR'
    };
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'TradingAccountCurrencyNotAllowed',
        params     => ['Deriv X'],
        rule       => $rule_name
        },
        'EUR is not allowed';

    $args = {
        loginid    => $vrtc->loginid,
        platform   => 'dxtrade',
        'currency' => 'USD'
    };
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'TradingAccountCurrencyNotAllowed',
        params     => ['Deriv X'],
        rule       => $rule_name
        },
        'USD is not allowed (vrtc account)';

    $available_currencies->{virtual} = {
        dxtrade => [qw/USD/],
    };

    ok $rule_engine->apply_rules($rule_name, %$args), 'Test passes with USD';

    $lc_mock->unmock_all;
};

subtest 'rule trading_account.client_should_be_real' => sub {
    my $rule_name = 'trading_account.client_support_account_creation';

    my $legacy = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code  => 'CR',
        account_type => 'binary'
    });
    my $rule_engine = BOM::Rules::Engine->new(client => $legacy);
    ok $rule_engine->apply_rules(
        $rule_name,
        loginid  => $legacy->loginid,
        platform => 'dxtrade'
        ),
        'Test passes with CR';

    my $trading = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code  => 'CR',
        account_type => 'standard'
    });
    $rule_engine = BOM::Rules::Engine->new(client => $trading);
    is_deeply exception { $rule_engine->apply_rules($rule_name, loginid => $trading->loginid, platform => 'dxtrade') },
        {
        error_code => 'PermissionDenied',
        rule       => $rule_name
        },
        'expected error when passing virtual account';

    my $df = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code  => 'CRW',
        account_type => 'doughflow'
    });
    $rule_engine = BOM::Rules::Engine->new(client => $df);
    ok $rule_engine->apply_rules(
        $rule_name,
        loginid  => $df->loginid,
        platform => 'dxtrade'
        ),
        'Test passes with CR';

    my $crypto = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code  => 'CRW',
        account_type => 'crypto'
    });

    $rule_engine = BOM::Rules::Engine->new(client => $crypto);
    is_deeply exception { $rule_engine->apply_rules($rule_name, loginid => $crypto->loginid, platform => 'dxtrade') },
        {
        error_code => 'PermissionDenied',
        rule       => $rule_name
        },
        'expected error when passing virtual account';
};

done_testing();
