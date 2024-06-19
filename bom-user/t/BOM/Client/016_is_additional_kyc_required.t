use strict;
use warnings;
use Test::More;
use Test::MockModule;

use BOM::User::Client;
use BOM::User;
use BOM::TradingPlatform;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

subtest 'additional kyc required' => sub {
    use_ok('BOM::User::Client');

    subtest 'standard client' => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code               => 'CR',
            tax_identification_number => '123456789',
            residence                 => 'id',
            tax_residence             => 'id',
            account_opening_reason    => 'trading',
            place_of_birth            => 'id',
        });

        my $user = BOM::User->create(
            email          => 'jurisdiction+poi@email.com',
            password       => BOM::User::Password::hashpw('asdf12345'),
            email_verified => 1,
        );
        $user->add_client($client);
        $user->add_loginid("MTR1234", 'mt5', 'real', 'USD', {group => 'test/test'});

        my @required_fields = qw(tax_identification_number tax_residence account_opening_reason place_of_birth);

        is($client->is_mt5_additional_kyc_required, 0, 'Additional KYC not required for id residence when all information is present');
        foreach my $field (@required_fields) {
            $client->$field('');

        }
        $client->save();

        is($client->is_mt5_additional_kyc_required, 1, 'Additional KYC required when fields are missing');
    };

    subtest 'mf client' => sub {
        my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code               => 'MF',
            tax_identification_number => '123456789',
            residence                 => 'id',
            tax_residence             => 'id',
            account_opening_reason    => 'trading',
            place_of_birth            => 'id',
        });

        my $user_mf = BOM::User->create(
            email          => 'jurisdiction+poi_mf@email.com',
            password       => BOM::User::Password::hashpw('asdf12345'),
            email_verified => 1,
        );
        $user_mf->add_client($client_mf);
        $user_mf->add_loginid("MTR1234", 'mt5', 'real', 'USD', {group => 'test/test'});

        is($client_mf->is_mt5_additional_kyc_required, 0, 'Additional KYC not required for MF clients');
    };

    subtest 'high risk client' => sub {
        my $jurisdiction = {
            bvi => {
                standard   => [qw/br/],
                restricted => [qw/id/],
                high       => [qw/ru/],
                revision   => 1,
            },
            vanuatu => {
                standard   => [qw/br/],
                restricted => [qw/id/],
                high       => [qw/ru/],
                revision   => 1,
            },
            labuan => {
                standard   => [qw/br/],
                restricted => [qw/id/],
                high       => [qw/ru/],
                revision   => 1,
            }};
        my $mock_config = Test::MockModule->new('BOM::Config::Compliance');
        $mock_config->redefine(
            get_risk_thresholds          => {},
            get_jurisdiction_risk_rating => sub { $jurisdiction });

        my $client_high_risk = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code               => 'CR',
            tax_identification_number => '',
            residence                 => 'id',
            tax_residence             => '',
            account_opening_reason    => '',
            place_of_birth            => '',
        });

        my $user_high_risk = BOM::User->create(
            email          => 'jurisdiction+poi_high_risk@email.com',
            password       => BOM::User::Password::hashpw('asdf12345'),
            email_verified => 1,
        );
        $user_high_risk->add_client($client_high_risk);
        $user_high_risk->add_loginid("MTR1234", 'mt5', 'real', 'USD', {group => 'test/test'});

        is($client_high_risk->is_mt5_additional_kyc_required, 0, 'Additional KYC not required for high risk CR clients');
    };
};

subtest 'skip additional kyc required check if the client does not have any mt5 account' => sub {
    use_ok('BOM::User::Client');

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'id',
    });

    my $user = BOM::User->create(
        email          => 'does_not_have_mt5_account@email.com',
        password       => BOM::User::Password::hashpw('asdf12345'),
        email_verified => 1,
    );
    $user->add_client($client);

    is($client->is_mt5_additional_kyc_required, 0, 'skip additional kyc required check if the client does not have any mt5 account');
};

done_testing();
