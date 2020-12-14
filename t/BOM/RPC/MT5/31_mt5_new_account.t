use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use JSON::MaybeUTF8;

use BOM::Test::RPC::QueueClient;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::MT5::User::Async;
use BOM::Platform::Token;
use BOM::User;

use Test::BOM::RPC::Accounts;

my $c = BOM::Test::RPC::QueueClient->new();

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my $m              = BOM::Platform::Token::API->new;
my %ACCOUNTS       = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %DETAILS        = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;
my %financial_data = %Test::BOM::RPC::Accounts::FINANCIAL_DATA;

subtest 'create mt5 client with different currency' => sub {
    subtest 'svg' => sub {
        my $new_email  = $DETAILS{email};
        my $new_client = create_client('CR');
        my $token      = $m->create_token($new_client->loginid, 'test token 2');
        $new_client->set_default_account('EUR');
        $new_client->email($new_email);

        my $user = BOM::User->create(
            email    => $new_email,
            password => 's3kr1t',
        );
        $user->add_client($new_client);

        my $method = 'mt5_new_account';
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_type => 'gaming',
                email        => $new_email,
                name         => $DETAILS{name},
                mainPassword => $DETAILS{password}{main},
                leverage     => 100,
            },
        };
        my $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
        is $result->{account_type}, 'gaming';
        is $result->{login},        'MTR' . $ACCOUNTS{'real01\synthetic\svg_std_usd'};

        my $new_client_vr = create_client('VRTC');
        $new_client_vr->set_default_account('GBP');
        $token = $m->create_token($new_client_vr->loginid, 'test token 2');
        $user->add_client($new_client_vr);

        BOM::RPC::v3::MT5::Account::reset_throttler($new_client->loginid);
        $params->{token} = $token;
        $c->call_ok($method, $params)->has_error->error_code_is('MT5CreateUserError')
            ->error_message_is(
            'An account already exists with the information you provided. If you\'ve forgotten your username or password, please contact us.');

        $params->{args}->{account_type} = 'demo';
        $result = $c->call_ok($method, $params)->has_no_error->result;
        is $result->{account_type}, 'demo';
        is $result->{login},        'MTD' . $ACCOUNTS{'demo01\synthetic\svg_std_usd'};
    };

    subtest 'mf - country=gb' => sub {
        my $client    = create_client('MF', undef, {residence => 'gb'});
        my $new_email = 'mf+eur@binary.com';
        $client->set_default_account('EUR');
        $client->aml_risk_classification('low');
        $client->account_opening_reason('speculative');
        $client->tax_residence('gb');
        $client->tax_identification_number('111-222-333');
        $client->email($new_email);
        $client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
        $client->save();

        my $user = BOM::User->create(
            email    => $new_email,
            password => 'Abcd33@!',
        );
        $user->add_client($client);
        my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

        my $method = 'mt5_new_account';
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_type     => 'financial',
                mt5_account_type => 'financial',
                email            => $new_email,
                name             => $DETAILS{name},
                mainPassword     => $DETAILS{password}{main},
                leverage         => 100,
            },
        };
        my $result = $c->call_ok($method, $params)->has_no_error('financial account successfully created')->result;
        is $result->{account_type}, 'financial';
        is $result->{login},        'MTR' . $ACCOUNTS{'real01\financial\maltainvest_std-hr_eur'};

        $client    = create_client('MF', undef, {residence => 'gb'});
        $new_email = 'mf+usd@binary.com';
        $client->set_default_account('USD');
        $client->aml_risk_classification('low');
        $client->account_opening_reason('speculative');
        $client->tax_residence('gb');
        $client->tax_identification_number('111-222-333');
        $client->email($new_email);
        $client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
        $client->save();

        $user = BOM::User->create(
            email    => $new_email,
            password => 'Abcd33@!',
        );
        $user->add_client($client);
        $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
        $params->{token} = $token;

        $result = $c->call_ok($method, $params)->has_no_error('financial account successfully created')->result;
        is $result->{account_type}, 'financial';
        is $result->{login},        'MTR' . $ACCOUNTS{'real01\financial\maltainvest_std-hr_gbp'};

        $client    = create_client('MF', undef, {residence => 'gb'});
        $new_email = 'mf+gbp@binary.com';
        $client->set_default_account('GBP');
        $client->aml_risk_classification('low');
        $client->account_opening_reason('speculative');
        $client->tax_residence('gb');
        $client->tax_identification_number('111-222-333');
        $client->email($new_email);
        $client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
        $client->save();

        $user = BOM::User->create(
            email    => $new_email,
            password => 'Abcd33@!',
        );
        $user->add_client($client);
        $token                      = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
        $params->{token}            = $token;
        $params->{args}->{currency} = 'EUR';
        BOM::RPC::v3::MT5::Account::reset_throttler($client->loginid);
        $c->call_ok($method, $params)->has_error->error_code_is('PermissionDenied')->error_message_is('Permission denied.');

        my $new_client_vr = create_client('VRTC', undef, {residence => 'gb'});
        $new_client_vr->set_default_account('USD');
        $token = $m->create_token($new_client_vr->loginid, 'test token 2');
        $user->add_client($new_client_vr);

        BOM::RPC::v3::MT5::Account::reset_throttler($client->loginid);
        $params->{token} = $token;
        $params->{args}->{account_type} = 'demo';
        delete $params->{args}->{currency};
        $result = $c->call_ok($method, $params)->has_no_error->result;
        is $result->{account_type}, 'demo';
        is $result->{login},        'MTD' . $ACCOUNTS{'demo01\financial\maltainvest_std_gbp'};
    };

    subtest 'mf - country=de' => sub {
        my $client    = create_client('MF', undef, {residence => 'de'});
        my $new_email = 'mfde+gbp@binary.com';
        $client->set_default_account('GBP');
        $client->aml_risk_classification('low');
        $client->account_opening_reason('speculative');
        $client->tax_residence('de');
        $client->tax_identification_number('111-222-333');
        $client->email($new_email);
        $client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
        $client->save();

        my $user = BOM::User->create(
            email    => $new_email,
            password => 'Abcd33@!',
        );
        $user->add_client($client);
        my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

        my $method = 'mt5_new_account';
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_type     => 'financial',
                mt5_account_type => 'financial',
                email            => $new_email,
                name             => $DETAILS{name},
                mainPassword     => $DETAILS{password}{main},
                leverage         => 100,
            },
        };

        BOM::RPC::v3::MT5::Account::reset_throttler($client->loginid);
        my $result = $c->call_ok($method, $params)->has_no_error('financial account successfully created')->result;
        is $result->{account_type}, 'financial';
        is $result->{login},        'MTR' . $ACCOUNTS{'real01\financial\maltainvest_std-hr_gbp'};

        $client    = create_client('MF', undef, {residence => 'de'});
        $new_email = 'mfde+usd@binary.com';
        $client->set_default_account('USD');
        $client->aml_risk_classification('low');
        $client->account_opening_reason('speculative');
        $client->tax_residence('de');
        $client->tax_identification_number('111-222-333');
        $client->email($new_email);
        $client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
        $client->save();

        $user = BOM::User->create(
            email    => $new_email,
            password => 'Abcd33@!',
        );
        $user->add_client($client);
        $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
        $params->{token} = $token;

        BOM::RPC::v3::MT5::Account::reset_throttler($client->loginid);
        $result = $c->call_ok($method, $params)->has_no_error('financial account successfully created')->result;
        is $result->{account_type}, 'financial';
        is $result->{login},        'MTR' . $ACCOUNTS{'real01\financial\maltainvest_std-hr_eur'};

        $client    = create_client('MF', undef, {residence => 'de'});
        $new_email = 'mfde+eur@binary.com';
        $client->set_default_account('EUR');
        $client->aml_risk_classification('low');
        $client->account_opening_reason('speculative');
        $client->tax_residence('de');
        $client->tax_identification_number('111-222-333');
        $client->email($new_email);
        $client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
        $client->save();

        $user = BOM::User->create(
            email    => $new_email,
            password => 'Abcd33@!',
        );
        $user->add_client($client);
        $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

        $params->{token} = $token;
        BOM::RPC::v3::MT5::Account::reset_throttler($client->loginid);
        $result = $c->call_ok($method, $params)->has_no_error('financial account successfully created')->result;
        is $result->{account_type}, 'financial';
        is $result->{login},        'MTR' . $ACCOUNTS{'real01\financial\maltainvest_std-hr_eur'};

        my $new_client_vr = create_client('VRTC', undef, {residence => 'de'});
        $new_client_vr->set_default_account('USD');
        $token = $m->create_token($new_client_vr->loginid, 'test token 2');
        $user->add_client($new_client_vr);

        BOM::RPC::v3::MT5::Account::reset_throttler($client->loginid);
        $params->{token} = $token;
        $params->{args}->{account_type} = 'demo';
        delete $params->{args}->{currency};
        $result = $c->call_ok($method, $params)->has_no_error->result;
        is $result->{account_type}, 'demo';
        is $result->{login},        'MTD' . $ACCOUNTS{'demo01\financial\maltainvest_std_eur'};
    };

    subtest 'mf - counrty=de no real' => sub {
        my $client    = create_client('VRTC', undef, {residence => 'de'});
        my $new_email = 'vrtcde+usd@binary.com';
        $client->set_default_account('USD');
        $client->aml_risk_classification('low');
        $client->account_opening_reason('speculative');
        $client->tax_residence('de');
        $client->tax_identification_number('111-222-333');
        $client->email($new_email);
        $client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
        $client->save();

        my $user = BOM::User->create(
            email    => $new_email,
            password => 'Abcd33@!',
        );
        $user->add_client($client);
        my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

        my $method = 'mt5_new_account';
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_type     => 'demo',
                mt5_account_type => 'financial',
                email            => $new_email,
                name             => $DETAILS{name},
                mainPassword     => $DETAILS{password}{main},
                leverage         => 100,
            },
        };

        BOM::RPC::v3::MT5::Account::reset_throttler($client->loginid);
        my $result = $c->call_ok($method, $params)->has_no_error('financial account successfully created')->result;
        is $result->{account_type}, 'demo';
        is $result->{login},        'MTD' . $ACCOUNTS{'demo01\financial\maltainvest_std_eur'};
    };
};

subtest 'auto b-booking' => sub {
    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->mock(fully_authenticated => sub { return 1 });
    my $new_email  = 'abc' . $DETAILS{email};
    my $new_client = create_client('CR');
    my $token      = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('EUR');
    $new_client->email($new_email);
    $new_client->aml_risk_classification('low');
    $new_client->account_opening_reason('speculative');
    $new_client->tax_residence('id');
    $new_client->tax_identification_number('111-222-333');
    $new_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
    $new_client->save();

    my $user = BOM::User->create(
        email    => $new_email,
        password => 's3kr1t',
    );
    $user->add_client($new_client);

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            email        => $new_email,
            name         => $DETAILS{name},
            mainPassword => $DETAILS{password}{main},
            leverage     => 100,
        },
    };

    note('set suspend auto b-book to true');
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->auto_Bbook_svg_financial(1);
    my $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
    is $result->{account_type}, 'gaming';
    is $result->{login}, 'MTR' . $ACCOUNTS{'real01\synthetic\svg_std_usd'}, 'gaming account not affected';

    $params->{args}->{account_type}     = 'financial';
    $params->{args}->{mt5_account_type} = 'financial';
    BOM::RPC::v3::MT5::Account::reset_throttler($new_client->loginid);
    $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
    is $result->{account_type}, 'financial';
    is $result->{login}, 'MTR' . $ACCOUNTS{'real01\financial\svg_std-hr_usd'}, 'routed to financial high risk';

    $params->{args}->{mt5_account_type} = 'financial_stp';
    BOM::RPC::v3::MT5::Account::reset_throttler($new_client->loginid);
    $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
    is $result->{account_type}, 'financial';
    is $result->{login}, 'MTR' . $ACCOUNTS{'real01\financial\labuan_stp_usd'}, 'financial stp account no high risk flag';
    #reset
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->auto_Bbook_svg_financial(0);
};

done_testing();
