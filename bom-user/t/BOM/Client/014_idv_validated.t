use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Deep;
use BOM::User::Client;
use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Customer;

subtest 'get_idv_verified' => sub {
    my $test_customer = BOM::Test::Customer->create(
        clients => [{
                name        => 'CR',
                broker_code => 'CR',
            }]);
    my $test_client_cr = $test_customer->get_client_object('CR');

    $test_client_cr->status->clear_age_verification();

    $test_client_cr->status->_build_all();

    my $client_mock = Test::MockModule->new(ref($test_client_cr));
    my @latest;
    $client_mock->mock(
        'latest_poi_by',
        sub {
            return @latest;
        });

    ok(!$test_client_cr->is_idv_validated(), 'Is not IDV Validated');    # Test for nothing

    @latest = ('onfido');

    ok(!$test_client_cr->is_idv_validated(), 'Onfido Is not IDV Validated');    # Test for Onfido

    @latest = ('idv');

    ok(!$test_client_cr->is_idv_validated(), 'is not IDV Validated (lacks age verification)');    # Test for IDV

    $test_client_cr->status->set('age_verification', 'test', 'test');

    ok($test_client_cr->is_idv_validated(), 'is IDV Validated');                                  # Test for IDV

    $client_mock->unmock_all;
};

subtest 'ignore age verification' => sub {
    my $test_customer = BOM::Test::Customer->create(
        clients => [{
                name        => 'CR',
                broker_code => 'CR',
            }]);
    my $client = $test_customer->get_client_object('CR');
    my $mock   = Test::MockModule->new(ref($client->status));
    my $idv_validated;

    $mock->mock(
        'is_idv_validated',
        sub {
            return $idv_validated;
        });

    $client->aml_risk_classification('low');
    $idv_validated = 0;

    ok !$client->status->is_idv_validated(), 'Not IDV validated';

    $client->aml_risk_classification('high');
    $idv_validated = 0;

    ok !$client->status->is_idv_validated(), 'Not IDV validated';

    $client->aml_risk_classification('low');
    $idv_validated = 1;

    ok $client->status->is_idv_validated(), 'IDV validated';

    $client->aml_risk_classification('high');
    $idv_validated = 1;

    ok $client->status->is_idv_validated(), 'IDV validated';

    $mock->unmock_all();
};

subtest 'onfido after idv validated' => sub {
    my $test_customer = BOM::Test::Customer->create(
        email_verified => 1,
        clients        => [{
                name        => 'CR',
                broker_code => 'CR',
            }]);
    my $client = $test_customer->get_client_object('CR');

    my $mock = Test::MockModule->new(ref($client));
    my @latest_poi_by;
    my @latest_verified_by;
    $mock->mock(
        'latest_poi_by',
        sub {
            my (undef, $args) = @_;

            return @latest_verified_by if $args->{only_verified};

            return @latest_poi_by;
        });

    my $get_last_updated_document;
    my $idv_mock = Test::MockModule->new('BOM::User::IdentityVerification');
    $idv_mock->mock(
        'get_last_updated_document',
        sub {
            return {
                status => $get_last_updated_document,
                id     => '1'
            };
        });

    $idv_mock->mock(
        'get_document_check_detail',
        sub {
            return {requested_at => '2020-01-01 10:10:10'};
        });
    # Submit POI through IDV
    $client->aml_risk_classification('low');
    $get_last_updated_document = 'verified';
    $client->status->setnx('age_verification', 'system', 'test');

    @latest_poi_by      = ('idv');
    @latest_verified_by = ('idv');
    ok $client->is_idv_validated(), 'IDV validated';
    is $client->get_onfido_status(),     'none',     'Should not be onfido validated';
    is $client->get_manual_poi_status(), 'none',     'Should not be manually validated';
    is $client->get_poi_status(),        'verified', 'POI status should be verified';
    is $client->get_idv_status(),        'verified', 'idv status should be verified';

    # Make user account into AML risk high (once user become AML risk high their identity .status will become none)

    @latest_poi_by      = ('idv');
    @latest_verified_by = ('idv');
    $client->aml_risk_classification('high');
    ok $client->is_idv_validated(), 'IDV validated';
    is $client->get_onfido_status(),     'none',     'Should not be onfido validated';
    is $client->get_manual_poi_status(), 'none',     'Should not be manually none';
    is $client->get_poi_status(),        'none',     'POI status should be none';
    is $client->get_idv_status(),        'verified', 'idv status should be verified';

    my $onfido_mock = Test::MockModule->new('BOM::User::Onfido');
    my $current_onfido_status;
    $onfido_mock->mock(
        'get_latest_check',
        sub {
            return {
                user_check                 => undef,
                report_document_status     => undef,
                report_document_sub_result => $current_onfido_status,
            };
        });
    $current_onfido_status = 'rejected';
    @latest_poi_by         = ('onfido');
    @latest_verified_by    = ('idv');

    ok $client->is_idv_validated(), 'is IDV validated';
    is $client->get_onfido_status(),     'rejected', 'Should be onfido rejected';
    is $client->get_manual_poi_status(), 'none',     'Should be manually none';
    is $client->get_poi_status(),        'rejected', 'POI status should be rejected';
    is $client->get_idv_status(),        'verified', 'idv status should be verified';

    $onfido_mock->mock(
        'get_latest_check',
        sub {
            return {
                user_check => {
                    result     => 'clear',
                    created_at => '2020-01-01 10:10:11',
                },
                report_document_status     => undef,
                report_document_sub_result => $current_onfido_status,
            };
        });
    $current_onfido_status = 'clear';
    @latest_poi_by         = ('onfido');
    @latest_verified_by    = ('onfido');

    $client->status->upsert('age_verification', 'system', 'onfido');
    ok !$client->is_idv_validated(), 'is not IDV validated';
    is $client->get_onfido_status(),     'verified', 'Should be onfido verified';
    is $client->get_manual_poi_status(), 'none',     'Should be manually none';
    is $client->get_poi_status(),        'verified', 'POI status should be verified';
    is $client->get_idv_status(),        'verified', 'idv status should be verified';

    $onfido_mock->mock(
        'get_latest_check',
        sub {
            return {
                user_check => {
                    result     => 'clear',
                    created_at => '2020-01-01 10:10:09',
                },
                report_document_status     => undef,
                report_document_sub_result => $current_onfido_status,
            };
        });
    $current_onfido_status = 'clear';

    @latest_poi_by      = ('onfido');
    @latest_verified_by = ('idv');
    ok $client->is_idv_validated(), 'is IDV validated';
    is $client->get_onfido_status(),     'verified', 'Should be onfido verified';
    is $client->get_manual_poi_status(), 'none',     'Should be manually none';
    is $client->get_poi_status(),        'none',     'POI status should be rejected';
    is $client->get_idv_status(),        'verified', 'idv status should be verified';

    $mock->unmock_all();
    $idv_mock->unmock_all();
    $onfido_mock->unmock_all();

};

done_testing();
