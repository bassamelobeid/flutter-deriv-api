use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use Test::BOM::RPC::QueueClient;
use LandingCompany::Registry;
use Scalar::Util qw/looks_like_number/;
use BOM::Platform::Token::API;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Email qw(:no_event);
use BOM::Test::Helper::Token;

BOM::Test::Helper::Token::cleanup_redis_tokens();

my $email       = 'abc@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::User::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client->email($email);
$test_client->save;

my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_vr->email($email);
$test_client_vr->save;

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->add_client($test_client);
$user->add_client($test_client_vr);

my $test_client_cr_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});

$test_client_cr_vr->email('sample@binary.com');
$test_client_cr_vr->save;

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    citizen     => 'at',
});
$test_client_cr->email('sample@binary.com');
$test_client_cr->set_default_account('USD');
$test_client_cr->save;

my $test_client_cr_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client_cr_2->email('sample@binary.com');
$test_client_cr_2->save;

my $user_cr = BOM::User->create(
    email    => 'sample@binary.com',
    password => $hash_pwd
);

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
        "set_financial_assessment"             => 1,
        "forex_trading_experience"             => "Over 3 years",                                     # +2
        "forex_trading_frequency"              => "0-5 transactions in the past 12 months",           # +0
        "binary_options_trading_experience"    => "1-2 years",                                        # +1
        "binary_options_trading_frequency"     => "40 transactions or more in the past 12 months",    # +2
        "cfd_trading_experience"               => "1-2 years",                                        # +1
        "cfd_trading_frequency"                => "0-5 transactions in the past 12 months",           # +0
        "other_instruments_trading_experience" => "Over 3 years",                                     # +2
        "other_instruments_trading_frequency"  => "6-10 transactions in the past 12 months",          # +1
        "employment_industry"                  => "Finance",                                          # +15
        "education_level"                      => "Secondary",                                        # +1
        "income_source"                        => "Self-Employed",                                    # +0
        "net_income"                           => '$25,000 - $50,000',                                # +1
        "estimated_worth"                      => '$100,000 - $250,000',                              # +1
        "occupation"                           => 'Managers',                                         # +0
        "employment_status"                    => "Self-Employed",                                    # +0
        "source_of_wealth"                     => "Company Ownership",                                # +0
        "account_turnover"                     => 'Less than $25,000',                                # +0
    };

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
    is($res->{total_score}, 27, "Got correct total score");

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

# Second set financial assessment test to test for changes only. (in this case forex_trading_experience went from "Over 3 years" to "1-2 years")
$method = 'set_financial_assessment';
subtest $method => sub {
    my $args = {
        "set_financial_assessment"             => 1,
        "forex_trading_experience"             => "1-2 years",                                        # +1
        "forex_trading_frequency"              => "0-5 transactions in the past 12 months",           # +0
        "binary_options_trading_experience"    => "1-2 years",                                        # +1
        "binary_options_trading_frequency"     => "40 transactions or more in the past 12 months",    # +2
        "cfd_trading_experience"               => "1-2 years",                                        # +1
        "cfd_trading_frequency"                => "0-5 transactions in the past 12 months",           # +0
        "other_instruments_trading_experience" => "Over 3 years",                                     # +2
        "other_instruments_trading_frequency"  => "6-10 transactions in the past 12 months",          # +1
        "employment_industry"                  => "Finance",                                          # +15
        "education_level"                      => "Secondary",                                        # +1
        "income_source"                        => "Self-Employed",                                    # +0
        "net_income"                           => '$25,000 - $50,000',                                # +1
        "estimated_worth"                      => '$100,000 - $250,000',                              # +1
        "occupation"                           => 'Managers',                                         # +0
        "employment_status"                    => "Self-Employed",                                    # +0
        "source_of_wealth"                     => "Company Ownership",                                # +0
        "account_turnover"                     => 'Less than $25,000',                                # +0
    };

    mailbox_clear();
    $c->tcall(
        $method,
        {
            args  => $args,
            token => $token
        });
    is($c->tcall('get_financial_assessment', {token => $token})->{forex_trading_experience}, "1-2 years", "forex_trading_experience changed");

    is $emit_args[0], 'set_financial_assessment', 'correct event name';
    is_deeply $emit_args[1],
        {
        'params'  => {'forex_trading_experience' => '1-2 years'},
        'loginid' => 'MF90000000'
        },
        'event args are correct';

    my $msg = mailbox_search(
        email   => 'compliance@deriv.com',
        subject => qr/assessment test details have been updated/
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
        email   => 'compliance@deriv.com',
        subject => qr/assessment test details have been updated/
    );

    ok(!$msg, 'no email sent when no change');
};

done_testing();
