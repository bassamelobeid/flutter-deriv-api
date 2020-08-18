use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use Test::BOM::RPC::Client;
use BOM::Test::Helper::FinancialAssessment;
use LandingCompany::Registry;
use BOM::RPC::v3::Utility;
use BOM::User::Password;
use BOM::User;
use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Scalar::Util qw/looks_like_number/;
use Email::Address::UseXS;
use Digest::SHA qw(hmac_sha256_hex);
use BOM::Test::Email qw(:no_event);

sub get_values {
    my $in = shift;
    my @vals;
    for my $v (values %$in) {
        push @vals => ref $v eq 'HASH' ? get_values($v) : $v;
    }
    return @vals;
}

# init db
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

my $m     = BOM::Platform::Token::API->new;
my $token = $m->create_token($test_client_cr->loginid, 'test token');

my $t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
my $c = Test::BOM::RPC::Client->new(ua => $t->app->ua);

my $method = 'payout_currencies';
subtest 'payout currencies' => sub {
    # we should not care about order of currencies
    # we just need to send array back
    cmp_bag($c->tcall($method, {token => '12345'}), [LandingCompany::Registry->new()->all_currencies()], 'invalid token will get all currencies');
    cmp_bag(
        $c->tcall(
            $method,
            {
                token => undef,
            }
        ),
        [LandingCompany::Registry->new()->all_currencies()],
        'undefined token will get all currencies'
    );

    cmp_bag($c->tcall($method, {token => $token}), ['USD'], "will return client's currency");
    cmp_bag($c->tcall($method, {}), [LandingCompany::Registry->new()->all_currencies()], "will return legal currencies if no token");
};

$method = 'landing_company';
subtest 'landing company' => sub {
    is_deeply(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                args     => {landing_company => 'nosuchcountry'}}
        ),
        {
            error => {
                message_to_client => '未知着陆公司。',
                code              => 'UnknownLandingCompany'
            }
        },
        "no such landing company"
    );
    my $ag_lc = $c->tcall($method, {args => {landing_company => 'ag'}});
    ok($ag_lc->{gaming_company},    "ag have gaming company");
    ok($ag_lc->{financial_company}, "ag have financial company");
    ok(!$c->tcall($method, {args => {landing_company => 'de'}})->{gaming_company},    "de have no gaming_company");
    ok(!$c->tcall($method, {args => {landing_company => 'hk'}})->{financial_company}, "hk have no financial_company");
};

$method = 'landing_company_details';
subtest 'landing company details' => sub {
    is_deeply(
        $c->tcall($method, {args => {landing_company_details => 'nosuchlandingcompany'}}),
        {
            error => {
                message_to_client => 'Unknown landing company.',
                code              => 'UnknownLandingCompany'
            }
        },
        "no such landing company"
    );
    my $result = $c->tcall($method, {args => {landing_company_details => 'svg'}});
    is($result->{name}, 'Binary (SVG) Ltd.', "details result ok");
    cmp_bag([keys %{$result->{currency_config}->{synthetic_index}}], [LandingCompany::Registry->new()->all_currencies()], "currency config ok");
    ok(!(grep { !looks_like_number($_) } get_values($result->{currency_config})), 'limits for svg are all numeric');

    $result = $c->tcall($method, {args => {landing_company_details => 'maltainvest'}});
    cmp_bag([keys %{$result->{currency_config}->{forex}}], ['USD', 'EUR', 'GBP'], "currency config for maltainvest ok");
    ok(!(grep { !looks_like_number($_) } get_values($result->{currency_config})), 'limits for maltainvest are all numeric');
};

$method = 'service_token';
subtest 'onfido service_token validation' => sub {
    $test_client->place_of_birth('');
    $test_client->residence('');
    $test_client->save;
    my $args = {
        service  => 'onfido',
        referrer => 'https://www.binary.com/'
    };
    # Tokens
    my $token = $m->create_token($test_client->loginid, 'test token');

    my $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args
        });
    is($res->{error}->{code}, 'MissingPersonalDetails', "Validation for Place of birth & residence passed.");
};

done_testing();
