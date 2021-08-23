use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::Exception;
use Test::MockModule;
use feature 'say';
use Data::Dumper;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::DevExperts;
use BOM::Platform::Token::API;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client;
use BOM::User;

my $c      = BOM::Test::RPC::QueueClient->new();
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

subtest 'identity_verification_document_add' => sub {

    BOM::User->create(
        email    => 'dxaccountsdfsdf@test.com',
        password => 'test'
    )->add_client($client);
    $client->account('USD');

    my $params = {language => 'EN'};

    $params->{args} = {
        issuing_country => 'xxx',
        document_type   => 'nin_slip',
        document_number => '01234564564',
    };

    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('NotSupportedCountry', 'Country code is not supported.');

    my $mock_countries = Test::MockModule->new('Brands::Countries');
    $mock_countries->mock(
        'is_idv_supported' => sub {
            my (undef, $country) = @_;
            return 1 if $country eq 'ng';
            return 0;
        });

    $params->{args} = {
        issuing_country => 'ng',
        document_type   => 'xxx',
        document_number => '001234564564',
    };

    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('InvalidDocumentType', 'Document type does not exist.');

    $mock_countries->mock(
        'get_idv_config' => sub {
            my (undef, $country) = @_;
            return {
                provider       => 'smile_identity',
                document_types => {nin_slip => {format => '^[0-9]+$'}}} if $country eq 'ng';
            return '';
        });

    $params->{args} = {
        issuing_country => 'ng',
        document_type   => 'nin_slip',
        document_number => '01test',
    };

    $c->call_ok('identity_verification_document_add', $params)
        ->has_no_system_error->has_error->error_code_is('InvalidDocumentNumber', 'Invalid document number.');

    $params->{args} = {
        issuing_country => 'ng',
        document_type   => 'nin_slip',
        document_number => '01',
    };

    $c->call_ok('identity_verification_document_add', $params)->has_no_system_error->has_no_error->result;
};

done_testing();
