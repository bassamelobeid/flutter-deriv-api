use strict;
use warnings;
use Test::Most;
use Test::FailWarnings;
use Test::Exception;
use BOM::Database::DataMapper::Client;
use BOM::Database::AutoGenerated::Rose::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $client_data_mapper;
subtest 'client_account_statistics' => sub {

    lives_ok {
        my $conn = BOM::Database::ClientDB->new({
            broker_code => 'CR',
        });

        my $first_client = BOM::Database::AutoGenerated::Rose::Client->new(
            loginid                  => 'CR656232',
            client_password          => 'angelina',
            email                    => 'bard1@pitt.com',
            broker_code              => 'CR',
            residence                => 'USA',
            citizen                  => 'USA',
            salutation               => 'MR',
            first_name               => 'bRaD',
            last_name                => 'pItT',
            address_line_1           => 'Civic Center',
            address_line_2           => '301',
            address_city             => 'Beverly Hills',
            address_state            => 'LA',
            address_postcode         => '232323',
            phone                    => '+112123121',
            latest_environment       => 'FireFox',
            secret_question          => 'How many child did I adopted',
            secret_answer            => 'its not your bussined',
            restricted_ip_address    => '',
            date_joined              => Date::Utility->new('20010108')->date_yyyymmdd,
            gender                   => 'm',
            cashier_setting_password => '',
            date_of_birth            => '1980-01-01',
        );

        $first_client->db($conn->db);
        $first_client->save();

        # we need third client to Coverage this method
        my $thi_client = BOM::Database::AutoGenerated::Rose::Client->new(
            loginid                  => 'CR656234',
            client_password          => 'angelina',
            email                    => 'bard3@pitt.com',
            broker_code              => 'CR',
            residence                => 'USA',
            citizen                  => 'USA',
            salutation               => 'Mrs',
            first_name               => 'angelina',
            last_name                => 'Jolie',
            address_line_1           => 'Civic Center',
            address_line_2           => '301',
            address_city             => 'Beverly Hills',
            address_state            => 'LA',
            address_postcode         => '232323',
            phone                    => '+112123121',
            latest_environment       => 'FireFox',
            secret_question          => 'How many child did I adopted',
            secret_answer            => 'its not your bussined',
            restricted_ip_address    => '',
            date_joined              => Date::Utility->new()->date_yyyymmdd,
            gender                   => 'm',
            cashier_setting_password => '',
            date_of_birth            => '1980-01-01',
        );
        $thi_client->db($conn->db);
        $thi_client->save();

    }
    ' Create two clients with same first name and last name';

    lives_ok {
        $client_data_mapper = BOM::Database::DataMapper::Client->new({
            broker_code => 'CR',
        });
    }
    'Expect to initialize the client data mapper';

    my $client_CR = BOM::Platform::Client->new({loginid => 'CR656234'});
    my $account = $client_CR->set_default_account('USD');

    subtest 'single deposit' => sub {
        $client_CR->payment_free_gift(
            currency    => 'USD',
            amount      => 100,
            remark      => 'free gift',
        );

        cmp_deeply(
            $client_data_mapper->get_account_statistics('CR656234'),
            {
                currency         => 'USD',
                balance          => '100.00',
                total_deposit    => '100.00',
                total_withdrawal => '0.00',
            });
    };

    subtest 'multiple deposit' => sub {

        $client_CR->payment_free_gift(
            currency    => 'USD',
            amount      => 200,
            remark      => 'free gift',
        );

        cmp_deeply(
            $client_data_mapper->get_account_statistics('CR656234'),
            {
                currency         => 'USD',
                balance          => '300.00',
                total_deposit    => '300.00',
                total_withdrawal => '0.00',
            });
    };

    subtest 'widrawal' => sub {

        $client_CR->payment_free_gift(
            currency    => 'USD',
            amount      => -200,
            remark      => 'free gift',
        );

        cmp_deeply(
            $client_data_mapper->get_account_statistics('CR656234'),
            {
                currency         => 'USD',
                balance          => '100.00',
                total_deposit    => '300.00',
                total_withdrawal => '-200.00',
            });
    };

};

subtest 'client_account_statistics' => sub {
    lives_ok {
        $client_data_mapper = BOM::Database::DataMapper::Client->new({
            client_loginid => 'CR656232',
        });
    }
    'Expect to initialize the client data mapper';

    ok($client_data_mapper->lock_client_loginid(), "Can lock client when there is no record in lock table initially.");
    cmp_ok(scalar keys %{$client_data_mapper->locked_client_list()}, '==', 1, "There is one locked client");

    ok(!$client_data_mapper->lock_client_loginid(),   "Can not lock client wheb it is already locked.");
    ok($client_data_mapper->unlock_client_loginid(),  "Can unlock client.");
    ok(!$client_data_mapper->unlock_client_loginid(), "Can not lock client if it is not locked.");

    ok($client_data_mapper->lock_client_loginid(),   "Can lock client again when the record exists in lock table.");
    ok($client_data_mapper->unlock_client_loginid(), "Can unlock client.");

    cmp_ok(scalar keys %{$client_data_mapper->locked_client_list()}, '==', 0, "There is no locked client");
};

done_testing;
