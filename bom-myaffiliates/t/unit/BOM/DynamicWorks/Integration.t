use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::MockObject;
use Test::Fatal;
use Test::Deep;
use Test::Trap;

use BOM::Test::Data::Utility::UnitTestDatabase           qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase           qw(:init);
use BOM::Test::Data::Utility::UnitTestCommissionDatabase qw(:init);

use BOM::MyAffiliates::DynamicWorks::Integration;
use BOM::MyAffiliates::DynamicWorks::DataBase::CommissionDBModel;

my $commission_db = BOM::MyAffiliates::DynamicWorks::DataBase::CommissionDBModel->new();

my $mock_syn_crm_requester = Test::MockModule->new("BOM::MyAffiliates::DynamicWorks::SyntellicoreCRMRequester");
my $mock_syn_requester     = Test::MockModule->new("BOM::MyAffiliates::DynamicWorks::SyntellicoreRequester");

my $mock_requester = Test::MockModule->new("BOM::MyAffiliates::DynamicWorks::Requester");

# Making sure that no request goes to the actual API
$mock_requester->mock('api_request', sub { return {data => []} });

my $mock_config = Test::MockModule->new("BOM::Config");

$mock_config->mock(
    'third_party',
    sub {
        return {
            dynamic_works => {
                syntellicore_crm => {
                    endpoint      => 'test',
                    user_login    => 'test_user',
                    user_password => 'test_password',
                    api_key       => 'test_api_key',
                    version       => 'test_version'
                },
                syntellicore => {
                    endpoint => 'test',
                    api_key  => 'test_api_key',
                    version  => 'test_version'
                },
            },
        };
    });

my $integration = BOM::MyAffiliates::DynamicWorks::Integration->new();

sub unmock_all {
    $mock_syn_crm_requester->unmock_all();
    $mock_syn_requester->unmock_all();
}

sub mock_all_good_paths {
    $mock_syn_crm_requester->mock(
        'getPartnerCampaigns',
        sub {
            return {
                data => [{
                        id         => 1,
                        title      => 'Test Campaign',
                        sidc       => 'random_token',
                        introducer => 'CU1234'
                    }]};
        });

    $mock_syn_requester->mock(
        'getCountries',
        sub {
            return {
                data => [{
                        currency         => "USD",
                        currency_id      => 1,
                        iso_alpha2_code  => "ID",
                        isocode3         => "IDN",
                        name             => "Indonesia",
                        show_on_register => 1,
                        tel_country_code => 62,
                    },
                ]};
        });

    $mock_syn_requester->mock(
        'createUser',
        sub {
            return {data => [{user => 'CU1234'}]};
        });

    $mock_syn_crm_requester->mock(
        'setCustomerTradingAccount',
        sub {
            return {data => [{account_id => '12345'}]};
        });

    $mock_syn_crm_requester->mock(
        'getProfiles',
        sub {
            my ($self, $args) = shift;

            return {
                success => 1,
                data    => [{account_id => 'CU1234', email => 'test@test.com'}]};
        });

}

subtest 'Test whole flow of linking all clients of user' => sub {

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        email       => 'testingbinaryuseridonly@test.com',
        broker_code => 'CR',
        residence   => 'id',
    });

    BOM::User->create(
        email          => $client->email,
        password       => "1234",
        email_verified => 1,
    )->add_client($client);

    my $user = $client->user;

    trap { $integration->link_user_to_affiliate({}) };

    like $trap->die, qr/binary_user_id is required/, 'Binary User ID not given';

    is $integration->link_user_to_affiliate({binary_user_id => $user->id}), undef, 'Returns undef if affiliated_client does not exist';

    $user->set_affiliated_client_details({
        provider => 'dynamicworks',
    });

    trap { $integration->link_user_to_affiliate({binary_user_id => $user->id}) };

    like $trap->die, qr/'sidc' is required as existing affiliated_client with partner token is not found/,
        'Dies if partner_token is not in affiliated_client';

    $user->update_affiliated_client_details({
        partner_token => 'random_token',
        provider      => 'dynamicworks'
    });

    $mock_syn_crm_requester->mock(
        'getPartnerCampaigns',
        sub {
            return {
                data => [],
                info => {message => "there aren't any campaigns for these criteria"}};
        });

    trap { $integration->link_user_to_affiliate({binary_user_id => $user->id}) };

    like $trap->die, qr/Error getting partner from sidc: there aren't any campaigns for these criteria/,
        'Dies if no campaigns found for the partner_token stored in affiliated_client';

    $mock_syn_crm_requester->mock(
        'getPartnerCampaigns',
        sub {
            return {
                data => [{
                        id         => 1,
                        title      => 'Test Campaign',
                        sidc       => 'random_token',
                        introducer => 'CU1234'
                    }]};
        });

    trap { $integration->link_user_to_affiliate({binary_user_id => $user->id}) };

    like $trap->die, qr/Affiliate not found with external_id: CU1234/,
        'Dies if affiliate is not found in affiliate.affiliate with the given affiliate_external_id';

    $commission_db->add_new_affiliate({
            binary_user_id        => 1,
            provider              => 'dynamicworks',
            payment_loginid       => 'CR90000001',
            external_affiliate_id => 'CU1234',
            payment_currency      => 'USD'

    });

    $mock_syn_requester->mock(
        'getCountries',
        sub {
            return {
                data => [],
                info => {message => "Error getting countries"}};
        });

    my $result = $integration->link_user_to_affiliate({binary_user_id => $user->id});

    like $result->{errors}->[0]->{error}, qr/Error getting countries/, 'Result unsuccessful as error in getting countries';

    $mock_syn_requester->mock(
        'getCountries',
        sub {
            return {
                data => [{
                        currency         => "USD",
                        currency_id      => 1,
                        iso_alpha2_code  => "ID",
                        isocode3         => "IDN",
                        name             => "Indonesia",
                        show_on_register => 1,
                        tel_country_code => 62,
                    },
                ]};
        });

    $mock_syn_requester->mock(
        'createUser',
        sub {
            return {
                data => [],
                info => {message => "Email already exists"}};
        });

    $result = $integration->link_user_to_affiliate({binary_user_id => $user->id});

    like $result->{errors}->[0]->{error}, qr/Error creating partner for user: Email already exists/, 'Result unsuccessful as error in creating user';

    $mock_syn_requester->mock(
        'createUser',
        sub {
            return {data => [{user => 'CU1234'}]};
        });

    $mock_syn_crm_requester->mock(
        'setCustomerTradingAccount',
        sub {
            return {
                data => [],
                info => {message => "Error creating account"}};
        });

    $result = $integration->link_user_to_affiliate({binary_user_id => $user->id});

    like $result->{errors}->[0]->{error}, qr/Error setting trading account for client/, 'Result unsuccessful as error in creating account';

    $mock_syn_crm_requester->mock(
        'setCustomerTradingAccount',
        sub {
            return {
                data => [
                    {random_key => 'random_value'},

                ],
                info => {message => "Random error message"}};
        });

    $result = $integration->link_user_to_affiliate({binary_user_id => $user->id});

    like $result->{errors}->[0]->{error}, qr/Error setting trading account for client/,
        'Result unsuccessful as error in creating trading account as setCustomerTradingAccount did not return an account id';

    $mock_syn_crm_requester->mock(
        'setCustomerTradingAccount',
        sub {
            return {data => [{account_id => '12345'}]};
        });

    $result = $integration->link_user_to_affiliate({binary_user_id => $user->id});

    is $result->{success} && !scalar @{result->{errors}}, 1, 'Result successful as setCustomerTradingAccount returned an account id';

    my $affiliate_clients =
        $commission_db->get_affiliate_clients({binary_user_id => $user->id, affiliate_external_id => 'CU1234'})->{affiliate_clients};

    is scalar @$affiliate_clients, 1, 'Affiliate client created in commission db';

    is $affiliate_clients->[0]->{binary_user_id},        $user->id,        'Correct binary_user_id inserted in commission db';
    is $affiliate_clients->[0]->{external_affiliate_id}, 'CU1234',         'Correct external_affiliate_id inserted in commission db';
    is $affiliate_clients->[0]->{platform},              'dtrade',         'Correct platform inserted in commission db';
    is $affiliate_clients->[0]->{id},                    $client->loginid, 'Correct id inserted in commission db';
    unmock_all;

};

subtest 'Testing for other platforms except MT5' => sub {

    my $platforms = ['dxtrade', 'deriv', 'ctrader'];

    my $mock_user = Test::MockModule->new('BOM::User');

    for my $platform (@$platforms) {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            email       => 'test' . $platform . '@test.com',
            broker_code => 'CR',
            residence   => 'id',
        });

        BOM::User->create(
            email          => $client->email,
            password       => "1234",
            email_verified => 1,
        )->add_client($client);

        my $user = $client->user;
        $user->set_affiliated_client_details({
            partner_token => 'random_token',
            provider      => 'dynamicworks'
        });

        $mock_user->mock(
            'clients',
            sub {
                return ($client);
            });

        my $platform_loginid;

        if ($platform eq 'dxtrade') {
            $platform_loginid = 'DXR90000001';
        } elsif ($platform eq 'deriv') {
            $platform_loginid = 'EZR90000001';
        } elsif ($platform eq 'ctrader') {
            $platform_loginid = 'CTR90000001';
        }

        $mock_user->mock(
            'loginid_details',
            sub {

                return {
                    $platform_loginid => {
                        platform   => $platform,
                        is_virtual => 0,
                        loginid    => $platform_loginid
                    }};
            });

        mock_all_good_paths;

        my $result = $integration->link_user_to_affiliate({binary_user_id => $user->id});

        is $result->{success} && !scalar @{result->{errors}}, 1, 'Result successful for platform: ' . $platform;

        my $affiliate_clients = $commission_db->get_affiliate_clients({binary_user_id => $user->id})->{affiliate_clients};

        is scalar @$affiliate_clients, 1, 'Affiliate client created in commission db for platform: ' . $platform;

        is $affiliate_clients->[0]->{binary_user_id}, $user->id, 'Correct binary_user_id inserted in commission db for platform: ' . $platform;
        is $affiliate_clients->[0]->{external_affiliate_id}, 'CU1234',
            'Correct external_affiliate_id inserted in commission db for platform: ' . $platform;
        is $affiliate_clients->[0]->{platform}, $platform,         'Correct platform inserted in commission db for platform: ' . $platform;
        is $affiliate_clients->[0]->{id},       $platform_loginid, 'Correct id inserted in commission db for platform: ' . $platform;

    }

    $mock_user->unmock_all;

    unmock_all;

};

subtest 'get profiles for user' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        email       => 'test@test.com',
        broker_code => 'CR',
        residence   => 'id',
    });

    my $user = BOM::User->create(
        email          => $client->email,
        password       => "1234",
        email_verified => 1,
    )->add_client($client);

    my $external_affiliate_id = 'CU1234';

    mock_all_good_paths();

    my $result = $integration->get_user_profiles($external_affiliate_id);

    is $result->[0]->{account_id}, $external_affiliate_id, 'Correct account_id returned';
    is $result->[0]->{email},      $user->email,           'Correct email returned';

};

$mock_config->unmock_all;
$mock_requester->unmock_all;

done_testing();
