use strict;
use warnings;

use Test::More;
use Test::Warnings qw(warning);
use Test::Fatal;
use Test::MockModule;
use Test::Deep;

use HTTP::Response;
use JSON::MaybeUTF8 qw( encode_json_utf8 );

use BOM::Event::Process;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

# Initiate test client
my $email = 'test1@bin.com';
my $user  = BOM::User->create(
    email          => $email,
    password       => "hello",
    email_verified => 1,
);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    binary_user_id => $user->id,
});
$user->add_client($client);

my $verification_status  = 'Verified';
my $personal_info_status = 'Returned';
my $personal_info        = {};
my $mock_http            = Test::MockModule->new('Net::Async::HTTP');
$mock_http->mock(
    POST => sub {
        my (undef, $url) = @_;

        my $res = HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    Actions => {
                        Verify_ID_Number     => $verification_status,
                        Return_Personal_Info => $personal_info_status,
                    },
                    $personal_info->%*,
                }));

        return Future->done($res);
    });    # prevent making real calls

my $mock_country_configs = Test::MockModule->new('Brands::Countries');
$mock_country_configs->mock(
    is_idv_supported => sub {
        my (undef, $country) = @_;

        return 0 if $country eq 'id';
        return 1;
    });

my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);

my $mock_idv_model = Test::MockModule->new('BOM::User::IdentityVerification');
$mock_idv_model->mock(submissions_left => 1);

my $idv_event_handler = BOM::Event::Process::get_action_mappings()->{identity_verification_requested};

my $args = {
    loginid => $client->loginid,
};

subtest 'verify identity basic' => sub {
    $args = {loginid => 'CR0'};
    like exception { $idv_event_handler->($args)->get }, qr/Could not instantiate client/i, 'Exception thrown for unknown client';

    $args = {
        loginid => $client->loginid,
    };

    like exception { $idv_event_handler->($args)->get }, qr/No standby document found/i, 'Exception thrown for user without standby document for IDV';

    $idv_model->add_document({
        issuing_country => 'id',
        number          => '123',
        type            => 'national_id'
    });
    is $idv_event_handler->($args)->get, undef, 'country only supported by onfido, event returned without processing';
};

subtest 'verify identity by smile_identity is passed and data are valid' => sub {
    $args = {
        loginid => $client->loginid,
    };

    my $updates = 0;
    $mock_idv_model->redefine(
        update_document_check => sub {
            $updates++;
            return $mock_idv_model->original('update_document_check')->(@_);
        });

    $idv_model->add_document({
        issuing_country => 'ke',
        number          => '12345',
        type            => 'national_id'
    });

    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1999-10-31');
    $client->save();

    $client->status->set('poi_name_mismatch');
    $client->status->clear_age_verification;

    $verification_status  = 'Verified';
    $personal_info_status = 'Returned';
    $personal_info        = {
        FullName => 'John Doe',
        DOB      => '1999-10-31'
    };

    is $idv_event_handler->($args)->get, undef, 'the event processed without error';
    is $updates, 2, 'update document triggered twice correctly';

    ok !$client->status->poi_name_mismatch, 'poi_name_mismatch is removed correctly';
    ok $client->status->age_verification, 'age verified correctly';
};

subtest 'verify identity by smile_identity is passed and data are not valid' => sub {
    $args = {
        loginid => $client->loginid,
    };

    my $updates = 0;
    $mock_idv_model->redefine(
        update_document_check => sub {
            $updates++;
            return $mock_idv_model->original('update_document_check')->(@_);
        });

    $idv_model->add_document({
        issuing_country => 'ke',
        number          => '12345',
        type            => 'national_id'
    });

    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1999-10-31');
    $client->save();

    $client->status->clear_poi_name_mismatch;
    $client->status->clear_age_verification;

    $verification_status  = 'Verified';
    $personal_info_status = 'Returned';
    $personal_info        = {
        FullName => 'James Watt',
        DOB      => Date::Utility->new->date
    };

    is $idv_event_handler->($args)->get, undef, 'the event processed without error';
    is $updates, 2, 'update document triggered twice correctly';

    ok $client->status->poi_name_mismatch, 'poi_name_mismatch is set correctly';
    ok !$client->status->age_verification, 'age verified not set correctly';

    $idv_model->add_document({
        issuing_country => 'ke',
        number          => '12345',
        type            => 'national_id'
    });
    $client->status->clear_poi_name_mismatch;
    $client->status->clear_age_verification;
    $updates = 0;

    $personal_info = {
        FullName => 'Hayedeh Mahastian',
        DOB      => 'Not Available'
    };

    is $idv_event_handler->($args)->get, undef, 'the event processed without error';
    is $updates, 2, 'update document triggered twice correctly';

    ok $client->status->poi_name_mismatch, 'poi_name_mismatch is set correctly';
    ok !$client->status->age_verification, 'age verified not set correctly';
};

done_testing();
