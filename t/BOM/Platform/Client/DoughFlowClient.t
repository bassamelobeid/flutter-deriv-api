use strict;
use warnings;

use Test::More qw(no_plan);
use Test::MockObject::Extends;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Client::DoughFlowClient;
use Date::Utility;
use DateTime;

my $user_detail1 = {
    email      => 'felix@regentmarkets.com',
    password   => 'abc123',
    residence  => 'au',
};
my $client_details1 = {
    'email'           => $user_detail1->{email},
    'residence'       => $user_detail1->{residence},
    'broker_code'     => 'CR',
    'allow_login'     => 1,
    'last_name'       => 'The cat',
    'first_name'      => 'Felix',
    'date_of_birth'   => '1951-01-01',
    'secret_question' => 'Name of your pet',
    'date_joined'     => Date::Utility->new->date_yyyymmdd,
    'latest_environment' =>
        '31-May-10 02h09GMT 99.99.99.63 Mozilla 5.0 (X11; U; Linux i686; en-US; rv:1.9.2.3) Gecko 20100401 Firefox 3.6.3 LANG=EN SKIN=',
    'cashier_setting_password' => '',
    'address_line_1'           => '11 Bligh St',
    'address_line_2'           => '',
    'address_city'             => 'Sydney',
    'address_postcode'         => '2000',
    'address_state'            => 'NSW',
    'secret_answer'            => '::ecp::52616e646f6d495633363368676674792dd36b78f1d98017',
    'restricted_ip_address'    => '',
    'salutation'               => 'Mr',
    'gender'                   => 'm',
    'phone'                    => '21345678',
    'comment'                  => '',
    'citizen'                  => 'au',
};

my $user_detail2 = {
    email      => 'felix@binary.com',
    password   => 'abc123',
    residence  => 'au',
};
my $client_details2 = {
    'email'           => $user_detail2->{email},
    'residence'       => $user_details2->{residence},
    'broker_code'     => 'CR',
    'allow_login'     => 1,
    'last_name'       => 'Dennis',
    'first_name'      => 'Felix',
    'date_of_birth'   => '1951-01-01',
    'secret_question' => 'Name of your pet',
    'date_joined'     => Date::Utility->new->date_yyyymmdd,
    'latest_environment' =>
        '31-May-10 02h09GMT 99.99.99.63 Mozilla 5.0 (X11; U; Linux i686; en-US; rv:1.9.2.3) Gecko 20100401 Firefox 3.6.3 LANG=EN SKIN=',
    'cashier_setting_password' => '',
    'address_line_1'           => '11 Bligh St',
    'address_line_2'           => '',
    'address_city'             => 'Sydney',
    'address_postcode'         => '2000',
    'address_state'            => 'NSW',
    'secret_answer'            => '::ecp::52616e646f6d495633363368676674792dd36b78f1d98017',
    'restricted_ip_address'    => '',
    'salutation'               => 'Mr',
    'gender'                   => 'm',
    'phone'                    => '21345678',
    'comment'                  => '',
    'citizen'                  => 'au'
};

subtest 'creating a DF client' => sub {
    my $vr_acc  = BOM::Platform::Account::Virtual::create_account({ details => $user_detail1 });
    my ($vr_client, $user) = @{$vr_acc}{'client', 'user'};
    $user->email_verified(1);
    $user->save;

    $client_details1->{client_password} = $vr_client->password;
    my $acc = BOM::Platform::Account::Real::default::create_account({
            from_client => $vr_client,
            user        => $user,
            country     => 'au',
            details     => $client_details1,
        });
    my $df_client = BOM::Platform::Client::DoughFlowClient->new({ loginid => $acc->{client}->loginid });

    is($df_client->CustName, 'Felix The cat',           'CustName correct');
    is($df_client->Street,   '11 Bligh St',             'Street correct');
    is($df_client->City,     'Sydney',                  'City correct');
    is($df_client->Province, 'NSW',                     'Province correct');
    is($df_client->Country,  'AU',                      'Country correct');
    is($df_client->PCode,    '2000',                    'PCode correct');
    is($df_client->Phone,    '21345678',                'Phone correct');
    is($df_client->Email,    'felix@regentmarkets.com', 'Email correct');
    is($df_client->DOB,      '1951-01-01',              'DOB correct');
    is($df_client->Gender,   'M',                       'Gender correct');
    is($df_client->Profile,  1,                         'Profile correct');
    is($df_client->Password, 'DO NOT USE',              'Password correct');
};

subtest 'Profile mapped correctly to DF levels' => sub {
    my $vr_acc  = BOM::Platform::Account::Virtual::create_account({ details => $user_detail2 });
    my ($vr_client, $user) = @{$vr_acc}{'client', 'user'};
    $user->email_verified(1);
    $user->save;

    $client_details2->{client_password} = $vr_client->password;
    my $acc = BOM::Platform::Account::Real::default::create_account({
            from_client => $vr_client,
            user        => $user,
            country     => 'au',
            details     => $client_details2,
        });
    my $loginid = $acc->{client}->loginid;
    $df_client = BOM::Platform::Client::DoughFlowClient->new({ loginid => $acc->{client}->loginid });

    my $mock_client = Test::MockObject::Extends->new($df_client);

    my $disabled = Test::MockObject->new();
    $disabled->set_always('status_code', 'disabled');

    $mock_client->set_always('client_status', ($disabled));
    is $mock_client->Profile, 0, 'Disabled client => 0';
    $mock_client->unmock('client_status');

    $mock_client->set_true(-is_vip);
    is $mock_client->Profile, 5, 'VIP client => 5';
    $mock_client->unmock('is_vip');

    is $mock_client->Profile, 1, 'Regular user => 1';

    $mock_client->set_status('age_verification');
    is $mock_client->Profile, 2, '.. and age verified => 2';

    $mock_client->set_true(-client_fully_authenticated);
    is $mock_client->Profile, 3, '... and authenticated identity => 3';

    $mock_client->set_always(-date_joined, DateTime->now->subtract(months => 6)->ymd);
    is $mock_client->Profile, 4, '.... and user for more than 6 months => 4';
};

subtest 'handling client data that require munging' => sub {
    local $client_details1->{'first_name'};

    $user_detail1->{'residence'} = 'af';

    $client_details1->{'first_name'}       = 'a';
    $client_details1->{'last_name'}        = 'a';
    $client_details1->{'address_line_1'}   = '';
    $client_details1->{'address_line_2'}   = 'a';
    $client_details1->{'address_city'}     = 'a';
    $client_details1->{'address_state'}    = '';
    $client_details1->{'address_postcode'} = 'T5T-0M2';

    my $vr_acc  = BOM::Platform::Account::Virtual::create_account({ details => $user_detail1 });
    my ($vr_client, $user) = @{$vr_acc}{'client', 'user'};
    $user->email_verified(1);
    $user->save;

    $client_details1->{client_password} = $vr_client->password;
    my $acc = BOM::Platform::Account::Real::default::create_account({
            from_client => $vr_client,
            user        => $user,
            country     => 'au',
            details     => $client_details1,
        });
    my $loginid = $acc->{client}->loginid;
    $df_client = BOM::Platform::Client::DoughFlowClient->new({ loginid => $acc->{client}->loginid });

    is($df_client->CustName, 'a aX',                    'munged CustName correct');
    is($df_client->Street,   'X',                       'munged Street correct');
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

