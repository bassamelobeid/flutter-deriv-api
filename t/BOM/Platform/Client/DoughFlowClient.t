use strict;
use warnings;

use Test::More qw(no_plan);
use Test::MockObject::Extends;
use Test::MockModule;
use Test::Deep;

use Date::Utility;
use BOM::User;

use BOM::Platform::Client::DoughFlowClient;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $user_client_cr = BOM::User->create(
    email          => 'cr@binary.com',
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);

my $client_details1 = {
    'loginid'            => 'CR5089',
    'email'              => 'felix@regentmarkets.com',
    'client_password'    => '960f984285701c6d8dba5dc71c35c55c0397ff276b06423146dde88741ddf1af',
    'binary_user_id'     => BOM::Test::Data::Utility::UnitTestDatabase::get_next_binary_user_id(),
    'broker_code'        => 'CR',
    'allow_login'        => 1,
    'last_name'          => 'The cat',
    'first_name'         => 'Felix',
    'date_of_birth'      => '1951-01-01',
    'secret_question'    => 'Name of your pet',
    'date_joined'        => Date::Utility->new->date_yyyymmdd,                                       # User joined today!
    'email'              => 'felix@regentmarkets.com',
    'latest_environment' =>
        '31-May-10 02h09GMT 99.99.99.63 Mozilla 5.0 (X11; U; Linux i686; en-US; rv:1.9.2.3) Gecko 20100401 Firefox 3.6.3 LANG=EN SKIN=',
    'cashier_setting_password' => '',
    'address_line_1'           => '11 Bligh St',
    'address_line_2'           => '',
    'address_city'             => 'Sydney',
    'address_postcode'         => '2000',
    'address_state'            => 'NSW',
    'residence'                => 'au',
    'secret_answer'            => '::ecp::52616e646f6d495633363368676674792dd36b78f1d98017',
    'restricted_ip_address'    => '',
    'loginid'                  => 'CR5089',
    'salutation'               => 'Mr',
    'last_name'                => 'The cat',
    'gender'                   => 'm',
    'phone'                    => '21345678',
    'comment'                  => '',
    'first_name'               => 'Felix',
    'citizen'                  => 'Brazil',
    non_pep_declaration_time   => Date::Utility->new->date_yyyymmdd,
    account_type               => 'doughflow',
};

my $client_details2 = {
    'loginid'            => 'CR5089',
    'email'              => 'felix@regentmarkets.com',
    'client_password'    => '960f984285701c6d8dba5dc71c35c55c0397ff276b06423146dde88741ddf1af',
    'binary_user_id'     => BOM::Test::Data::Utility::UnitTestDatabase::get_next_binary_user_id(),
    'broker_code'        => 'CR',
    'allow_login'        => 1,
    'last_name'          => 'Dennis',
    'first_name'         => 'Felix',
    'date_of_birth'      => '1951-01-01',
    'secret_question'    => 'Name of your pet',
    'date_joined'        => Date::Utility->new->date_yyyymmdd,                                       # User joined today!
    'email'              => 'felix@regentmarkets.com',
    'latest_environment' =>
        '31-May-10 02h09GMT 99.99.99.63 Mozilla 5.0 (X11; U; Linux i686; en-US; rv:1.9.2.3) Gecko 20100401 Firefox 3.6.3 LANG=EN SKIN=',
    'cashier_setting_password' => '',
    'address_line_1'           => '11 Bligh St',
    'address_line_2'           => '',
    'address_city'             => 'Sydney',
    'address_postcode'         => '2000',
    'address_state'            => 'NSW',
    'residence'                => 'au',
    'secret_answer'            => '::ecp::52616e646f6d495633363368676674792dd36b78f1d98017',
    'restricted_ip_address'    => '',
    'loginid'                  => 'CR5089',
    'salutation'               => 'Mr',
    'last_name'                => 'Dennis',
    'gender'                   => 'm',
    'phone'                    => '21345678',
    'comment'                  => '',
    'first_name'               => 'Felix',
    'citizen'                  => 'Brazil',
    non_pep_declaration_time   => Date::Utility->new->date_yyyymmdd,
    account_type               => 'doughflow',
};

my $df_client;

subtest 'creating a DF client' => sub {
    $df_client = BOM::Platform::Client::DoughFlowClient->register_and_return_new_client($client_details1);
    $user_client_cr->add_client($df_client);

    is($df_client->CustName,   'Felix The cat',           'CustName correct');
    is($df_client->Street,     '11 Bligh St',             'Street correct');
    is($df_client->City,       'Sydney',                  'City correct');
    is($df_client->Province,   'NSW',                     'Province correct');
    is($df_client->Country,    'AU',                      'Country correct');
    is($df_client->PCode,      '2000',                    'PCode correct');
    is($df_client->Phone,      '21345678',                'Phone correct');
    is($df_client->Email,      'felix@regentmarkets.com', 'Email correct');
    is($df_client->DOB,        '1951-01-01',              'DOB correct');
    is($df_client->Gender,     'M',                       'Gender correct');
    is($df_client->Profile,    1,                         'Profile correct');
    is($df_client->Password,   'DO NOT USE',              'Password correct');
    is($df_client->NationalID, undef,                     'No Document');

    my $bag = $df_client->create_customer_property_bag({
        SecurePassCode => 'test',
        Sportsbook     => 'foo',
        IP_Address     => '127.0.0.1',
        Password       => 'bar',
    });

    cmp_deeply $bag,
        +{
        CustName       => 'Felix The cat',
        Email          => 'felix@regentmarkets.com',
        DOB            => '1951-01-01',
        City           => 'Sydney',
        SecurePassCode => 'test',
        PCode          => '2000',
        Sportsbook     => 'foo',
        Phone          => '21345678',
        IP_Address     => '127.0.0.1',
        Profile        => 1,
        Gender         => 'M',
        Password       => 'bar',
        Province       => 'NSW',
        Street         => '11 Bligh St',
        Country        => 'AU',
        PIN            => 'CR10000',
        },
        'Expected bag resolved';

    subtest 'residence not ZA' => sub {
        subtest 'with IDV document from ZA' => sub {
            my $idv_mock = Test::MockModule->new('BOM::User::IdentityVerification');

            $idv_mock->mock(
                'get_last_updated_document',
                sub {
                    return {
                        document_number => '12345',
                        issuing_country => 'za'
                    };
                });

            is($df_client->NationalID, undef, 'There is a document number');

            my $bag = $df_client->create_customer_property_bag({
                SecurePassCode => 'test',
                Sportsbook     => 'foo',
                IP_Address     => '127.0.0.1',
                Password       => 'bar',
            });

            cmp_deeply $bag,
                +{
                CustName       => 'Felix The cat',
                Email          => 'felix@regentmarkets.com',
                DOB            => '1951-01-01',
                City           => 'Sydney',
                SecurePassCode => 'test',
                PCode          => '2000',
                Sportsbook     => 'foo',
                Phone          => '21345678',
                IP_Address     => '127.0.0.1',
                Profile        => 1,
                Gender         => 'M',
                Password       => 'bar',
                Province       => 'NSW',
                Street         => '11 Bligh St',
                Country        => 'AU',
                PIN            => 'CR10000',
                },
                'Expected bag resolved';

            $idv_mock->unmock_all;
        };

        subtest 'with IDV document from BR' => sub {
            my $idv_mock = Test::MockModule->new('BOM::User::IdentityVerification');

            $idv_mock->mock(
                'get_last_updated_document',
                sub {
                    return {
                        document_number => '12345',
                        issuing_country => 'br'
                    };
                });

            is($df_client->NationalID, undef, 'Only ZA is allowed');

            my $bag = $df_client->create_customer_property_bag({
                SecurePassCode => 'test',
                Sportsbook     => 'foo',
                IP_Address     => '127.0.0.1',
                Password       => 'bar',
            });

            cmp_deeply $bag,
                +{
                CustName       => 'Felix The cat',
                Email          => 'felix@regentmarkets.com',
                DOB            => '1951-01-01',
                City           => 'Sydney',
                SecurePassCode => 'test',
                PCode          => '2000',
                Sportsbook     => 'foo',
                Phone          => '21345678',
                IP_Address     => '127.0.0.1',
                Profile        => 1,
                Gender         => 'M',
                Password       => 'bar',
                Province       => 'NSW',
                Street         => '11 Bligh St',
                Country        => 'AU',
                PIN            => 'CR10000',
                },
                'Expected bag resolved';

            $idv_mock->unmock_all;
        };
    };

    subtest 'residence is ZA' => sub {
        $df_client->residence('za');
        $df_client->save;

        subtest 'with IDV document from ZA' => sub {
            my $idv_mock = Test::MockModule->new('BOM::User::IdentityVerification');

            $idv_mock->mock(
                'get_last_updated_document',
                sub {
                    return {
                        document_number => '12345',
                        issuing_country => 'za'
                    };
                });

            is($df_client->NationalID, '12345', 'There is a document number');

            my $bag = $df_client->create_customer_property_bag({
                SecurePassCode => 'test',
                Sportsbook     => 'foo',
                IP_Address     => '127.0.0.1',
                Password       => 'bar',
            });

            cmp_deeply $bag,
                +{
                CustName       => 'Felix The cat',
                NationalID     => '12345',
                Email          => 'felix@regentmarkets.com',
                DOB            => '1951-01-01',
                City           => 'Sydney',
                SecurePassCode => 'test',
                PCode          => '2000',
                Sportsbook     => 'foo',
                Phone          => '21345678',
                IP_Address     => '127.0.0.1',
                Profile        => 1,
                Gender         => 'M',
                Password       => 'bar',
                Province       => 'NSW',
                Street         => '11 Bligh St',
                Country        => 'ZA',
                PIN            => 'CR10000',
                },
                'Expected bag resolved';

            $idv_mock->unmock_all;
        };

        subtest 'with IDV document from BR' => sub {
            my $idv_mock = Test::MockModule->new('BOM::User::IdentityVerification');

            $idv_mock->mock(
                'get_last_updated_document',
                sub {
                    return {
                        document_number => '12345',
                        issuing_country => 'br'
                    };
                });

            is($df_client->NationalID, undef, 'Only ZA is allowed');

            my $bag = $df_client->create_customer_property_bag({
                SecurePassCode => 'test',
                Sportsbook     => 'foo',
                IP_Address     => '127.0.0.1',
                Password       => 'bar',
            });

            cmp_deeply $bag,
                +{
                CustName       => 'Felix The cat',
                Email          => 'felix@regentmarkets.com',
                DOB            => '1951-01-01',
                City           => 'Sydney',
                SecurePassCode => 'test',
                PCode          => '2000',
                Sportsbook     => 'foo',
                Phone          => '21345678',
                IP_Address     => '127.0.0.1',
                Profile        => 1,
                Gender         => 'M',
                Password       => 'bar',
                Province       => 'NSW',
                Street         => '11 Bligh St',
                Country        => 'ZA',
                PIN            => 'CR10000',
                },
                'Expected bag resolved';

            $idv_mock->unmock_all;
        };
    };

    $df_client->residence('au');
    $df_client->save;
};

subtest 'Profile mapped correctly to DF levels' => sub {
    $df_client = BOM::Platform::Client::DoughFlowClient->register_and_return_new_client($client_details2);
    $user_client_cr->add_client($df_client);

    my $mock_client = Test::MockObject::Extends->new($df_client);
    my $mock_status = Test::MockObject::Extends->new($df_client->status);
    $mock_client->set_always('status', ($mock_status));

    $mock_status->set_always('disabled', {});
    is $mock_client->Profile, 0, 'Disabled client => 0';
    $mock_status->unmock('disabled');

    is $mock_client->Profile, 1, 'Regular user => 1';

    $mock_client->status->set('age_verification');
    is $mock_client->Profile, 2, '.. and age verified => 2';

    $mock_client->set_true(-fully_authenticated);
    is $mock_client->Profile, 3, '... and authenticated identity => 3';

    $mock_client->set_always(-date_joined, Date::Utility->new->minus_time_interval("6mo")->date_yyyymmdd);
    is $mock_client->Profile, 4, '.... and user for more than 6 months => 4';
};

subtest 'handling client data that require munging' => sub {
    local $client_details1->{'first_name'};

    $client_details1->{'first_name'}       = 'a';
    $client_details1->{'last_name'}        = 'a';
    $client_details1->{'address_line_1'}   = '';
    $client_details1->{'address_line_2'}   = 'a';
    $client_details1->{'address_city'}     = 'a';
    $client_details1->{'address_state'}    = '';
    $client_details1->{'residence'}        = 'af';
    $client_details1->{'address_postcode'} = 'T5T-0M2';

    $df_client = BOM::Platform::Client::DoughFlowClient->register_and_return_new_client($client_details1);
    $user_client_cr->add_client($df_client);

    is($df_client->CustName, 'a aX',                    'munged CustName correct');
    is($df_client->Street,   '',                        'munged Street correct');
    is($df_client->City,     'aX',                      'City correct');
    is($df_client->Province, '',                        'If we are not in the US,CA,AU,GB, we cant munge this appropriately.');
    is($df_client->Country,  'AF',                      'Country correct');
    is($df_client->PCode,    'T5T-0M2',                 'PCode correct');
    is($df_client->Phone,    '21345678',                'Phone correct');
    is($df_client->Email,    'felix@regentmarkets.com', 'Email correct');
    is($df_client->DOB,      '1951-01-01',              'DOB correct');
    is($df_client->Gender,   'M',                       'Gender correct');
    is($df_client->Profile,  1,                         'Profile correct');
    is($df_client->Password, 'DO NOT USE',              'Password correct');
};

subtest 'doughflow_currency' => sub {
    my $client = BOM::Platform::Client::DoughFlowClient->new({loginid => 'MX0012'});
    is($client->doughflow_currency, 'GBP', 'DF currency for MX clients is always GBP');
};

