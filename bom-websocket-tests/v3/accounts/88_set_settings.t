use strict;
use warnings;
use Test::More;
use Test::Deep;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_consumer_groups_request/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Customer;
use BOM::Platform::Account::Virtual;
use BOM::Database::Model::OAuth;
use await;

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::User::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $t = build_wsapi_test();

my %client_details = (
    new_account_real       => 1,
    salutation             => 'Ms',
    last_name              => 'last-name',
    first_name             => 'first-name',
    date_of_birth          => '1990-12-30',
    residence              => 'au',
    place_of_birth         => 'de',
    address_line_1         => 'Jalan Usahawan',
    address_line_2         => 'Enterpreneur Center',
    address_city           => 'Cyberjaya',
    address_postcode       => '47120',
    phone                  => '+60321685000',
    secret_question        => 'Favourite dish',
    secret_answer          => 'nasi lemak,teh tarik',
    account_opening_reason => 'Speculative'
);

subtest 'Address validation' => sub {
    my $customer = BOM::Test::Customer->create(
        email_verified => 1,
        account_type   => 'binary',
        residence      => 'br',
        clients        => [{
                name            => 'VRTC',
                broker_code     => 'VRTC',
                default_account => 'USD',
            },
        ]);
    my $vr_client = $customer->get_client_object('VRTC');
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);

    $t->await::authorize({authorize => $token});
    my $cli_details = {
        %client_details,
        residence      => 'br',
        first_name     => 'Homer',
        last_name      => 'Thompson',
        address_line_1 => '123° Fake Street',
        address_line_2 => '123° Evergreen Terrace',
    };

    my $res = $t->await::new_account_real($cli_details);
    test_schema('new_account_real', $res);

    my $loginid = $res->{new_account_real}->{client_id};
    ok $loginid, 'We got a client loginid';

    my ($cr_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
    $t->await::authorize({authorize => $cr_token});

    my $set_settings_params = {
        set_settings   => 1,
        address_line_1 => '8504° Lake of Terror',
        address_line_2 => '1122ºD',
        salutation     => 'Ms'
    };

    $res = $t->await::set_settings($set_settings_params);
    test_schema('set_settings', $res);

    my $cli = BOM::User::Client->new({loginid => $loginid});
    is $cli->address_line_1, $set_settings_params->{address_line_1}, 'Expected address line 1';
    is $cli->address_line_2, $set_settings_params->{address_line_2}, 'Expected address line 2';
};

subtest 'Tax residence on restricted country' => sub {
    my $customer = BOM::Test::Customer->create(
        email_verified => 1,
        account_type   => 'binary',
        residence      => 'br',
        clients        => [{
                name            => 'VRTC',
                broker_code     => 'VRTC',
                default_account => 'USD',
            },
        ]);
    my $vr_client = $customer->get_client_object('VRTC');
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});
    my $cli_details = {
        %client_details,
        residence     => 'br',
        first_name    => 'Mr',
        last_name     => 'Familyman',
        date_of_birth => '1990-12-30',
    };

    my $res = $t->await::new_account_real($cli_details);
    test_schema('new_account_real', $res);

    my $loginid = $res->{new_account_real}->{client_id};
    ok $loginid, 'We got a client loginid';

    my ($cr_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
    $t->await::authorize({authorize => $cr_token});

    my $set_settings_params = {
        set_settings  => 1,
        tax_residence => 'my',
        salutation    => 'Mr'
    };

    $res = $t->await::set_settings($set_settings_params);
    test_schema('set_settings', $res);

    my $cli = BOM::User::Client->new({loginid => $loginid});
    is $cli->tax_residence, $set_settings_params->{tax_residence}, 'Expected tax residence';

    $set_settings_params = {
        set_settings   => 1,
        salutation     => 'Mrs',
        address_line_1 => 'Lake of Rage 123',
        address_state  => 'Amazonas'
    };

    $res = $t->await::set_settings($set_settings_params);
    test_schema('set_settings', $res);
    $cli = BOM::User::Client->new({loginid => $loginid});
    is $cli->address_line_1, $set_settings_params->{address_line_1},
        'Successfully called /set_settings under restricted country in tax residence scenario';
    is $cli->address_state, 'AM', 'State name is converted into state code';
};

subtest 'feature flag test' => sub {
    # Set feature flag from virtual account
    # get feature flag from real account
    # compare the results to make sure it has been set on user level
    my $customer = BOM::Test::Customer->create(
        email_verified => 1,
        account_type   => 'binary',
        residence      => 'br',
        clients        => [{
                name            => 'VRTC',
                broker_code     => 'VRTC',
                default_account => 'USD',
            },
        ]);
    my $vr_client = $customer->get_client_object('VRTC');
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    my $feature_flag = {wallet => 1};

    my $set_settings_params = {
        set_settings => 1,
        feature_flag => $feature_flag
    };

    my $res = $t->await::set_settings($set_settings_params);
    test_schema('set_settings', $res);
    my $cli_details = {
        %client_details,
        residence     => 'br',
        first_name    => 'Feature',
        last_name     => 'Flag',
        date_of_birth => '1998-12-11',
    };

    $res = $t->await::new_account_real($cli_details);
    test_schema('new_account_real', $res);

    my $loginid = $res->{new_account_real}->{client_id};
    ok $loginid, 'We got a client loginid';

    my ($cr_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
    $t->await::authorize({authorize => $cr_token});

    my $get_settings_params = {
        get_settings => 1,
    };

    $res = $t->await::get_settings($get_settings_params);
    test_schema('get_settings', $res);

    my $feature_flag_res = $res->{get_settings}->{feature_flag};

    foreach my $flag (keys $feature_flag->%*) {
        is $feature_flag->{$flag}, $feature_flag_res->{$flag}, "flag $flag has been set correctly";
    }
};

subtest 'Phone Number verified' => sub {
    my $customer = BOM::Test::Customer->create(
        email_verified => 1,
        account_type   => 'binary',
        residence      => 'br',
        phone          => '+55990000001',
        clients        => [{
                name            => 'CR',
                broker_code     => 'CR',
                default_account => 'USD',
            },
        ]);

    my $client = $customer->get_client_object('CR');

    my $token = $customer->get_client_token('CR', ['admin']);
    $t->await::authorize({authorize => $token});

    my $params = {
        set_settings => 1,
    };

    my $customer2 = BOM::Test::Customer->create(
        email_verified => 1,
        account_type   => 'binary',
        residence      => 'br',
        phone          => $client->phone,
        clients        => [{
                name            => 'CR',
                broker_code     => 'CR',
                default_account => 'USD',
            },
        ]);

    my $token2 = $customer2->get_client_token('CR', ['admin']);

    my $params2 = {
        set_settings => 1,
    };

    $params->{phone} = $client->phone;

    my $result = $t->await::set_settings($params);
    test_schema('set_settings', $result);

    ok $result->{set_settings}, 'No error on set_settings call';

    $params2->{phone} = $params->{phone};

    $t->await::authorize({authorize => $token2});
    $result = $t->await::set_settings($params2);
    test_schema('set_settings', $result);

    $params2->{phone} = '+55990000002';

    $result = $t->await::set_settings($params2);
    test_schema('set_settings', $result);

    ok $result->{set_settings}, 'No error on set_settings call';

    my $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());
    $pnv->verify($params->{phone});
    $params2->{phone} = $params->{phone};

    $result = $t->await::set_settings($params2);
    test_schema('set_settings', $result);

    cmp_deeply $result->{error},
        +{
        message => 'The phone number is not available.',
        code    => 'PhoneNumberTaken',
        },
        'Expected error when number is taken';

    delete $params2->{phone};
    $params2->{address_city} = 'Sao Paulo';

    $result = $t->await::set_settings($params2);
    test_schema('set_settings', $result);

    ok $result->{set_settings}, 'No error on set_settings call (no phone updated)';

    $pnv->release();
    $params2->{phone} = $params->{phone};

    $result = $t->await::set_settings($params2);
    test_schema('set_settings', $result);

    ok $result->{set_settings}, 'No error on set_settings call';
};

$t->finish_ok;

done_testing;
