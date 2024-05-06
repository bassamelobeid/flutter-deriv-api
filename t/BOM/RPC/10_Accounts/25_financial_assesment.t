use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use Test::BOM::RPC::QueueClient;
use Scalar::Util qw/looks_like_number/;
use BOM::Platform::Token::API;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Email                           qw(:no_event);
use BOM::Test::Helper::Token;
use BOM::Platform::Context qw (request);
use BOM::Test::Helper::FinancialAssessment;
use JSON::MaybeUTF8 qw(encode_json_utf8);

BOM::Test::Helper::Token::cleanup_redis_tokens();

my $email    = 'abc@binary.com';
my $password = 'jskjd8292922';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'MF',
    binary_user_id => $user->id,
});

$test_client->email($email);
$test_client->save;

my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'VRTC',
    binary_user_id => $user->id,
});
$test_client_vr->email($email);
$test_client_vr->save;

$user->add_client($test_client);
$user->add_client($test_client_vr);

my $user_cr = BOM::User->create(
    email    => 'sample@binary.com',
    password => $hash_pwd
);

my $test_client_cr_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'VRTC',
    binary_user_id => $user_cr->id,
});

$test_client_cr_vr->email('sample@binary.com');
$test_client_cr_vr->save;

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    citizen        => 'at',
    binary_user_id => $user_cr->id,
});
$test_client_cr->email('sample@binary.com');
$test_client_cr->set_default_account('USD');
$test_client_cr->save;

my $test_client_cr_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    binary_user_id => $user_cr->id,
});
$test_client_cr_2->email('sample@binary.com');
$test_client_cr_2->save;

$user_cr->add_client($test_client_cr_vr);
$user_cr->add_client($test_client_cr);
$user_cr->add_client($test_client_cr_2);

my $test_client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

my $test_client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client_disabled->status->set('disabled', 1, 'test disabled');

my $test_client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
    residence   => 'gb',
    citizen     => ''
});
$test_client_mx->email($email);

my $test_client_vr_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_vr_2->email($email);
$test_client_vr_2->set_default_account('USD');
$test_client_vr_2->save;

my $email_mlt_mf    = 'mltmf@binary.com';
my $test_client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MLT',
    residence   => 'at',
});
$test_client_mlt->email($email_mlt_mf);
$test_client_mlt->set_default_account('EUR');
$test_client_mlt->save;

my $test_client_mlt_loginid = $test_client_mlt->loginid;

my $test_client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
    residence   => 'at',
});
$test_client_mf->email($email_mlt_mf);
$test_client_mf->save;

my $user_mlt_mf = BOM::User->create(
    email    => $email_mlt_mf,
    password => $hash_pwd
);
$user_mlt_mf->add_client($test_client_vr_2);
$user_mlt_mf->add_client($test_client_mlt);
$user_mlt_mf->add_client($test_client_mf);

my $test_client_only_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_only_vr->email('only_vr@binary.com');
$test_client_only_vr->save;

my $user_only_vr = BOM::User->create(
    email    => 'only_vr@binary.com',
    password => $hash_pwd
);
$user_only_vr->add_client($test_client_vr);

my $m             = BOM::Platform::Token::API->new;
my $token         = $m->create_token($test_client->loginid,         'test token');
my $token_cr      = $m->create_token($test_client_cr->loginid,      'test token');
my $token_cr_2    = $m->create_token($test_client_cr_2->loginid,    'test token');
my $token_vr      = $m->create_token($test_client_vr->loginid,      'test token');
my $token_mlt     = $m->create_token($test_client_mlt->loginid,     'test token');
my $token_mf      = $m->create_token($test_client_mf->loginid,      'test token');
my $token_only_vr = $m->create_token($test_client_only_vr->loginid, 'test token');

my $c = Test::BOM::RPC::QueueClient->new;

my @emit_args;
my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_emitter->mock(
    'emit' => sub {
        @emit_args = @_;
    });

my $method = 'get_financial_assessment';
subtest 'get financial assessment' => sub {
    my $args = {"get_financial_assessment" => 1};
    my $res  = $c->tcall(
        $method,
        {
            token => $token_only_vr,
            args  => $args
        });
    is($res->{error}->{code}, 'PermissionDenied', "Not allowed for an account that only has virtual.");

    $res = $c->tcall(
        $method,
        {
            args  => $args,
            token => $token
        });
    is_deeply($res, {}, 'empty assessment details');
};

$method = 'set_financial_assessment';
subtest 'set financial assessment' => sub {
    my $args = {
        "set_financial_assessment" => 1,
        "financial_information"    => {
            "employment_industry" => "Finance",                # +15
            "education_level"     => "Secondary",              # +1
            "income_source"       => "Self-Employed",          # +0
            "net_income"          => '$25,000 - $50,000',      # +1
            "estimated_worth"     => '$100,000 - $250,000',    # +1
            "occupation"          => 'Managers',               # +0
            "employment_status"   => "Self-Employed",          # +0
            "source_of_wealth"    => "Company Ownership",      # +0
            "account_turnover"    => 'Less than $25,000',
        },
        "trading_experience_regulated" => {
            "risk_tolerance"                           => "Yes",
            "source_of_experience"                     => "I have an academic degree, professional certification, and/or work experience.",
            "cfd_experience"                           => "Less than a year",
            "cfd_frequency"                            => "1 - 5 transactions in the past 12 months",
            "trading_experience_financial_instruments" => "Less than a year",
            "trading_frequency_financial_instruments"  => "1 - 5 transactions in the past 12 months",
            "cfd_trading_definition"                   => "Speculate on the price movement.",
            "leverage_impact_trading"                  => "Leverage lets you open larger positions for a fraction of the trade's value.",
            "leverage_trading_high_risk_stop_loss"     => "Close your trade automatically when the loss is more than or equal to a specific amount.",
            "required_initial_margin"                  => "When opening a Leveraged CFD trade.",
        }};

    my $res = $c->tcall(
        $method,
        {
            token => $token_vr,
            args  => $args
        });
    is($res->{error}->{code}, 'PermissionDenied', "Not allowed for virtual account");

    $res = $c->tcall(
        $method,
        {
            args  => $args,
            token => $token
        });
    is($res->{total_score}, 28, "Got correct total score");

    # test that setting this for one client also sets it for client with different landing company
    is($c->tcall('get_financial_assessment', {token => $token_mlt})->{source_of_wealth}, undef, "Financial assessment not set for MLT client");
    is($c->tcall('get_financial_assessment', {token => $token_mf})->{source_of_wealth},  undef, "Financial assessment not set for MF clinet");

    $c->tcall(
        $method,
        {
            args  => $args,
            token => $token_mf
        });

    is($c->tcall('get_financial_assessment', {token => $token_mf})->{source_of_wealth}, "Company Ownership",
        "Financial assessment set for MF client");
    is(
        $c->tcall('get_financial_assessment', {token => $token_mlt})->{source_of_wealth},
        "Company Ownership",
        "Financial assessment set for MLT client"
    );
    is(
        $c->tcall('get_financial_assessment', {token => $token_vr})->{source_of_wealth},
        "Company Ownership",
        "Financial assessment is accessible for VRTC client"
    );
    # test that setting this for one client sets it for clients with same landing company
    is($c->tcall('get_financial_assessment', {token => $token_cr})->{source_of_wealth},   undef, "Financial assessment not set for CR client");
    is($c->tcall('get_financial_assessment', {token => $token_cr_2})->{source_of_wealth}, undef, "Financial assessment not set for second CR clinet");
    mailbox_clear();

    $c->tcall(
        $method,
        {
            args  => $args,
            token => $token_cr_2
        });
    is($c->tcall('get_financial_assessment', {token => $token_cr})->{source_of_wealth}, "Company Ownership",
        "Financial assessment set for CR client");
    is(
        $c->tcall('get_financial_assessment', {token => $token_cr_2})->{source_of_wealth},
        "Company Ownership",
        "Financial assessment set for second CR client"
    );

    my $msg = mailbox_search(
        email   => 'compliance@deriv.com',
        subject => qr/has submitted the assessment test/
    );
    ok(!$msg, 'no email for CR submitting FA');

};

$method = 'get_financial_assessment';
subtest $method => sub {
    my $args = {"get_financial_assessment" => 1};

    my $res = $c->tcall(
        $method,
        {
            token => $token_only_vr,
            args  => $args
        });
    is($res->{error}->{code}, 'PermissionDenied', "Not allowed for virtual account");

    $res = $c->tcall(
        $method,
        {
            args  => $args,
            token => $token
        });
    is $res->{education_level}, 'Secondary', 'Got correct answer for assessment key';
};

# Second set financial assessment test to test for changes only. (in this case cfd_experience went from "Less than a year" to "1 - 2 years")
$method = 'set_financial_assessment';
subtest $method => sub {
    my $args = {
        "set_financial_assessment" => 1,
        "financial_information"    => {
            "employment_industry" => "Finance",                # +15
            "education_level"     => "Secondary",              # +1
            "income_source"       => "Self-Employed",          # +0
            "net_income"          => '$25,000 - $50,000',      # +1
            "estimated_worth"     => '$100,000 - $250,000',    # +1
            "occupation"          => 'Managers',               # +0
            "employment_status"   => "Self-Employed",          # +0
            "source_of_wealth"    => "Company Ownership",      # +0
            "account_turnover"    => 'Less than $25,000',
        },
        "trading_experience_regulated" => {
            "risk_tolerance"                           => "Yes",
            "source_of_experience"                     => "I have an academic degree, professional certification, and/or work experience.",
            "cfd_experience"                           => "1 - 2 years",
            "cfd_frequency"                            => "1 - 5 transactions in the past 12 months",
            "trading_experience_financial_instruments" => "Less than a year",
            "trading_frequency_financial_instruments"  => "1 - 5 transactions in the past 12 months",
            "cfd_trading_definition"                   => "Speculate on the price movement.",
            "leverage_impact_trading"                  => "Leverage lets you open larger positions for a fraction of the trade's value.",
            "leverage_trading_high_risk_stop_loss"     => "Close your trade automatically when the loss is more than or equal to a specific amount.",
            "required_initial_margin"                  => "When opening a Leveraged CFD trade.",
        }};

    mailbox_clear();
    $c->tcall(
        $method,
        {
            args  => $args,
            token => $token
        });
    is($c->tcall('get_financial_assessment', {token => $token})->{cfd_experience}, "1 - 2 years", "cfd_experience changed");

    is $emit_args[0], 'set_financial_assessment', 'correct event name';
    is_deeply $emit_args[1],
        {
        'params'  => {'cfd_experience' => '1 - 2 years'},
        'loginid' => 'MF90000000'
        },
        'event args are correct';
    my $brand = request->brand;
    my $msg   = mailbox_search(
        email   => $brand->emails('compliance_ops'),
        subject => qr/has updated the trading assessment/
    );
    ok($msg, 'send a email to compliance for MF after changing financial assessment');
    # make call again but with same arguments

    mailbox_clear();

    $c->tcall(
        $method,
        {
            args  => $args,
            token => $token
        });

    $msg = mailbox_search(
        email   => $brand->emails('compliance_ops'),
        subject => qr/has updated the trading assessment/
    );

    ok(!$msg, 'no email sent when no change');
};

$method = 'get_financial_assessment';
subtest $method => sub {
    my $args = {"get_financial_assessment" => 1};
    my $res  = $c->tcall(
        $method,
        {
            token => $token_vr,
            args  => $args
        });

    is $res->{education_level}, 'Secondary', 'Got correct answer for assessment key for duplicate accounts';

    $test_client->status->set('duplicate_account', 'system', 'Duplicate account - currency change');
    ok $test_client->status->duplicate_account, "MF Account is set as duplicate_account";
    $res = $c->tcall(
        $method,
        {
            token => $token_vr,
            args  => $args
        });
    is $res->{education_level}, 'Secondary', 'Got correct answer for assessment key for duplicate accounts';

    $test_client->status->clear_duplicate_account;
    $test_client->status->set('duplicate_account', 'system', 'Duplicate account - different reason');
    $res = $c->tcall(
        $method,
        {
            token => $token_vr,
            args  => $args
        });

    is($res->{error}->{code}, 'PermissionDenied', "Not allowed for Duplicate account");
};

subtest 'MF duplicated account' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    my $client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    my $virtual = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    my $user = BOM::User->create(
        email    => 'dup+get+fa@binary.com',
        password => 'Abcd1234'
    );
    $user->add_client($client);
    $user->add_client($virtual);

    my $data = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();
    $client->financial_assessment({
        data => encode_json_utf8($data),
    });
    $client->save();

    $token = $m->create_token($virtual->loginid, 'virtual token');
    my $result = $c->tcall('get_financial_assessment', {token => $token});

    $client->status->set('duplicate_account', 'system', 'Duplicate account - currency change');

    my $result2 = $c->tcall('get_financial_assessment', {token => $token});

    cmp_deeply $result, $result2, 'Same result before and after the dup';

    subtest 'FA from MF real' => sub {
        $user->add_client($client2);
        ok !$client2->financial_assessment, 'client2 does not have a FA';

        my $result3 = $c->tcall('get_financial_assessment', {token => $token});

        cmp_deeply $result, $result3, 'Same result before and after the dup';
    };
};

$method = 'set_financial_assessment';
subtest 'set financial assessment with occupation handled with default values' => sub {
    my @broker_codes = ('CR', 'MF');
    for my $broker_code (@broker_codes) {
        my $email    = 'default_unemployed' . $broker_code . '@deriv.com';
        my $password = 'secret_pwd';

        my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => $broker_code});

        $test_client->email($email);
        $test_client->save;

        my $user = BOM::User->create(
            email    => $email,
            password => $hash_pwd
        );
        $user->add_client($test_client);

        my $token = $m->create_token($test_client->loginid, 'test token');

        my $args = {
            "set_financial_assessment" => 1,
            "financial_information"    => {
                "employment_industry" => "Finance",
                "education_level"     => "Secondary",
                "income_source"       => "Self-Employed",
                "net_income"          => '$25,000 - $50,000',
                "estimated_worth"     => '$100,000 - $250,000',
                "employment_status"   => "Unemployed",
                "source_of_wealth"    => "Company Ownership",
                "account_turnover"    => 'Less than $25,000',
            },
            "trading_experience_regulated" => {
                "risk_tolerance"                           => "Yes",
                "source_of_experience"                     => "I have an academic degree, professional certification, and/or work experience.",
                "cfd_experience"                           => "Less than a year",
                "cfd_frequency"                            => "1 - 5 transactions in the past 12 months",
                "trading_experience_financial_instruments" => "Less than a year",
                "trading_frequency_financial_instruments"  => "1 - 5 transactions in the past 12 months",
                "cfd_trading_definition"                   => "Speculate on the price movement.",
                "leverage_impact_trading"                  => "Leverage lets you open larger positions for a fraction of the trade's value.",
                "leverage_trading_high_risk_stop_loss" => "Close your trade automatically when the loss is more than or equal to a specific amount.",
                "required_initial_margin"              => "When opening a Leveraged CFD trade.",
            }};

        $c->tcall(
            $method,
            {
                args  => $args,
                token => $token
            });

        my $result = $c->tcall('get_financial_assessment', {token => $token});
        is $result->{employment_status}, 'Unemployed', 'Employment Status Unemployed';
        is $result->{occupation},        'Unemployed', "Occupation defaulted to Unemployed for Employment Status Unemployed for $broker_code";

        $args->{financial_information}->{employment_status} = "Self-Employed";

        $c->tcall(
            $method,
            {
                args  => $args,
                token => $token
            });

        $result = $c->tcall('get_financial_assessment', {token => $token});
        is $result->{employment_status}, 'Self-Employed', 'Employment Status Self-Employed';
        is $result->{occupation}, 'Self-Employed', "Occupation defaulted to Self-Employed for Employment Status Self-Employed for $broker_code";

        subtest 'skipping the implicit employment_status' => sub {
            $args->{financial_information}->{employment_status} = 'Pensioner';
            $args->{financial_information}->{occupation}        = 'Managers';

            $c->tcall(
                $method,
                {
                    args  => $args,
                    token => $token
                });

            my $result = $c->tcall('get_financial_assessment', {token => $token});
            is $result->{employment_status}, 'Pensioner', 'Employment Status Self-Employed';
            is $result->{occupation},        'Managers',  "Occupation changed to Managers for $broker_code";

            delete $args->{financial_information}->{employment_status};
            delete $args->{financial_information}->{occupation};

            $c->tcall(
                $method,
                {
                    args  => $args,
                    token => $token
                });

            $result = $c->tcall('get_financial_assessment', {token => $token});
            is $result->{employment_status}, 'Pensioner', 'Employment Status is still Pensioner';
            is $result->{occupation},        'Managers',  "Occupation is still Managers for $broker_code";

            $args->{financial_information}->{employment_status} = 'Self-Employed';
            delete $args->{financial_information}->{occupation};

            $c->tcall(
                $method,
                {
                    args  => $args,
                    token => $token
                });

            $result = $c->tcall('get_financial_assessment', {token => $token});
            is $result->{employment_status}, 'Self-Employed', 'Employment Status changed to Self-Employed';
            is $result->{occupation},        'Self-Employed', "Occupation defaulted to Self-Employed for $broker_code";

            delete $args->{financial_information}->{employment_status};
            delete $args->{financial_information}->{occupation};

            $c->tcall(
                $method,
                {
                    args  => $args,
                    token => $token
                });

            is $result->{employment_status}, 'Self-Employed', 'Employment Status is still Self-Employed';
            is $result->{occupation},        'Self-Employed', "Occupation is still Self-Employed for $broker_code";

            $args->{financial_information}->{employment_status} = 'Unemployed';
            delete $args->{financial_information}->{occupation};

            $c->tcall(
                $method,
                {
                    args  => $args,
                    token => $token
                });

            $result = $c->tcall('get_financial_assessment', {token => $token});
            is $result->{employment_status}, 'Unemployed', 'Employment Status changed to Unemployed';
            is $result->{occupation},        'Unemployed', "Occupation is defaulted to Unemployed for $broker_code";

            delete $args->{financial_information}->{employment_status};
            delete $args->{financial_information}->{occupation};

            $c->tcall(
                $method,
                {
                    args  => $args,
                    token => $token
                });

            is $result->{employment_status}, 'Unemployed', 'Employment Status is still Unemployed';
            is $result->{occupation},        'Unemployed', "Occupation is still Unemployed for $broker_code";
        };
    }
};

done_testing();
