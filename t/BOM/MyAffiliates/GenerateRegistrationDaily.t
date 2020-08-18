use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Test::MockModule;

use Brands;

use BOM::MyAffiliates::GenerateRegistrationDaily;
use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

subtest 'client with no promocode' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code                   => 'CR',
        date_joined                   => Date::Utility->new->date_yyyymmdd,
        source                        => 1,
        myaffiliates_token            => 'dummy_affiliate_token',
        myaffiliates_token_registered => 0
    });

    my $processing_date = Date::Utility->new->plus_time_interval('2d');
    my $reporter        = BOM::MyAffiliates::GenerateRegistrationDaily->new(
        brand           => Brands->new(name => 'binary'),
        processing_date => $processing_date,
    );
    is $reporter->output_file_path(), '/db/myaffiliates/binary/registrations_' . $processing_date->date_yyyymmdd . '.csv',
        'Output file path is correct';

    my $mock_module = Test::MockModule->new('BOM::MyAffiliates::GenerateRegistrationDaily');
    $mock_module->mock('force_backfill', sub { 1 });

    my @activity_data = $reporter->activity();

    my $is_new_client_reported = grep { $_ =~ $client->loginid } @activity_data;
    ok $is_new_client_reported, "Created client is now on the new-registrations list to report to my affiliates";
};

subtest 'client with promocode' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code                   => 'CR',
        date_joined                   => Date::Utility->new->date_yyyymmdd,
        source                        => 1,
        myaffiliates_token            => 'dummy_affiliate_token',
        myaffiliates_token_registered => 0
    });

    $client->promo_code('BOM2009');
    $client->save;

    my $processing_date = Date::Utility->new->plus_time_interval('2d');
    my $reporter        = BOM::MyAffiliates::GenerateRegistrationDaily->new(
        brand           => Brands->new(name => 'binary'),
        processing_date => $processing_date,
    );
    is $reporter->output_file_path(), '/db/myaffiliates/binary/registrations_' . $processing_date->date_yyyymmdd . '.csv',
        'Output file path is correct';

    my $mock_module = Test::MockModule->new('BOM::MyAffiliates::GenerateRegistrationDaily');
    $mock_module->mock('force_backfill', sub { 1 });

    my @activity_data = $reporter->activity();

    my $is_new_client_reported = grep { $_ =~ $client->loginid } @activity_data;
    ok !$is_new_client_reported,
        "Created client is not on the new-registrations list to report to affiliates as client has promocode but checked in myaffiliates as false";

    $client->db->dbic->run(
        ping => sub {
            $_->do("UPDATE betonmarkets.client_promo_code SET checked_in_myaffiliates = ? WHERE client_loginid = ? AND promotion_code = ?",
                undef, 1, $client->loginid, 'BOM2009');
        });

    $reporter = BOM::MyAffiliates::GenerateRegistrationDaily->new(
        brand           => Brands->new(name => 'binary'),
        processing_date => $processing_date,
    );

    @activity_data = $reporter->activity();

    $is_new_client_reported = grep { $_ =~ $client->loginid } @activity_data;
    ok $is_new_client_reported,
        "Created client is now on the new-registrations list to report to affiliates as client has promocode and checked in myaffiliates is true";
};

subtest 'client with no promocode - brands' => sub {
    subtest 'deriv' => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code                   => 'CR',
            date_joined                   => Date::Utility->new->date_yyyymmdd,
            source                        => 11780,                               # deriv app id
            myaffiliates_token            => 'dummy_affiliate_token',
            myaffiliates_token_registered => 0
        });

        my $processing_date = Date::Utility->new->plus_time_interval('2d');
        my $reporter        = BOM::MyAffiliates::GenerateRegistrationDaily->new(
            brand           => Brands->new(name => 'deriv'),
            processing_date => $processing_date,
        );
        is $reporter->output_file_path(), '/db/myaffiliates/deriv/registrations_' . $processing_date->date_yyyymmdd . '.csv',
            'Output file path is correct';

        my $mock_module = Test::MockModule->new('BOM::MyAffiliates::GenerateRegistrationDaily');
        $mock_module->mock('force_backfill', sub { 1 });

        my @activity_data          = $reporter->activity();
        my $is_new_client_reported = grep { $_ =~ $client->loginid } @activity_data;
        ok $is_new_client_reported, "Created client is now on the new-registrations list to report to my affiliates";
    };

    subtest 'binary' => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code                   => 'CR',
            date_joined                   => Date::Utility->new->date_yyyymmdd,
            source                        => 113,                                 # random app id
            myaffiliates_token            => 'dummy_affiliate_token',
            myaffiliates_token_registered => 0
        });

        my $processing_date = Date::Utility->new->plus_time_interval('2d');
        my $reporter        = BOM::MyAffiliates::GenerateRegistrationDaily->new(
            brand           => Brands->new(name => 'binary'),
            processing_date => $processing_date,
        );
        is $reporter->output_file_path(), '/db/myaffiliates/binary/registrations_' . $processing_date->date_yyyymmdd . '.csv',
            'Output file path is correct';

        my $mock_module = Test::MockModule->new('BOM::MyAffiliates::GenerateRegistrationDaily');
        $mock_module->mock('force_backfill', sub { 1 });

        my @activity_data          = $reporter->activity();
        my $is_new_client_reported = grep { $_ =~ $client->loginid } @activity_data;
        ok $is_new_client_reported,
            "Created client is now on the new-registrations list to report to my affiliates for binary brand - any un-official app is included in binary brand";
    };
};

done_testing();
