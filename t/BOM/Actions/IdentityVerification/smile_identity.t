use strict;
use warnings;

use Test::More;
use Test::MockModule;

use Future::Exception;
use HTTP::Response;
use JSON::MaybeUTF8 qw( encode_json_utf8 );

use BOM::Config::Redis;
use BOM::Event::Process;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User::IdentityVerification;

# Initiate test client
my $email = 'testw@binary.com';
my $user  = BOM::User->create(
    email          => $email,
    password       => "pwd",
    email_verified => 1,
);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    binary_user_id => $user->id,
});
$user->add_client($client);

my ($resp, $verification_status, $personal_info_status, $personal_info, $args) = undef;
my $updates = 0;

my $mock_idv_model = Test::MockModule->new('BOM::User::IdentityVerification');
$mock_idv_model->redefine(
    update_document_check => sub {
        $updates++;
        return $mock_idv_model->original('update_document_check')->(@_);
    });

my $mock_http = Test::MockModule->new('Net::Async::HTTP');
$mock_http->mock(
    POST => sub {
        return $resp->() if ref $resp eq 'CODE';
        return $resp;
    });    # prevent making real calls

my $mock_country_configs = Test::MockModule->new('Brands::Countries');
$mock_country_configs->mock(
    is_idv_supported => sub {
        my (undef, $country) = @_;

        return 0 if $country eq 'id';
        return 1;
    });

my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);

my $idv_event_handler = BOM::Event::Process::get_action_mappings()->{identity_verification_requested};

subtest 'verify identity by smile_identity is passed and data are valid' => sub {
    $args = {
        loginid => $client->loginid,
    };

    $updates = 0;

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

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    Actions => {
                        Verify_ID_Number     => $verification_status,
                        Return_Personal_Info => $personal_info_status,
                    },
                    $personal_info->%*,
                },
            )));

    ok $idv_event_handler->($args)->get, 'the event processed without error';
    is $updates, 2, 'update document triggered twice correctly';

    ok !$client->status->poi_name_mismatch, 'poi_name_mismatch is removed correctly';
    ok $client->status->age_verification, 'age verified correctly';
};

subtest 'verify identity by smile_identity is passed and name mismatched' => sub {
    $args = {
        loginid => $client->loginid,
    };

    $updates = 0;

    $idv_model->add_document({
        issuing_country => 'ke',
        number          => '12345',
        type            => 'national_id'
    });

    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1999-10-31');
    $client->save();

    _reset_submissions($client->binary_user_id);
    $client->status->clear_poi_name_mismatch;
    $client->status->clear_age_verification;

    $verification_status  = 'Verified';
    $personal_info_status = 'Returned';
    $personal_info        = {
        FullName => 'James Watt',
        DOB      => Date::Utility->new->date
    };

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    Actions => {
                        Verify_ID_Number     => $verification_status,
                        Return_Personal_Info => $personal_info_status,
                    },
                    $personal_info->%*,
                },
            )));

    ok $idv_event_handler->($args)->get, 'the event processed without error';
    is $updates, 2, 'update document triggered twice correctly';

    is $idv_model->submissions_left, 0, 'submissions reset to 0 correctly';
    ok $client->status->poi_name_mismatch, 'poi_name_mismatch is set correctly';
    ok !$client->status->age_verification, 'age verified not set correctly';

    $idv_model->add_document({
        issuing_country => 'ke',
        number          => '12345',
        type            => 'national_id'
    });

    _reset_submissions($client->binary_user_id);
    $client->status->clear_poi_name_mismatch;
    $client->status->clear_age_verification;
    $updates = 0;

    $personal_info = {
        FullName => 'Hayedeh Mahastian',
        DOB      => 'Not Available'
    };

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    Actions => {
                        Verify_ID_Number     => $verification_status,
                        Return_Personal_Info => $personal_info_status,
                    },
                    $personal_info->%*,
                },
            )));

    ok $idv_event_handler->($args)->get, 'the event processed without error';
    is $updates, 2, 'update document triggered twice correctly';

    is $idv_model->submissions_left, 0, 'submissions reset to 0 correctly';
    ok $client->status->poi_name_mismatch, 'poi_name_mismatch is set correctly';
    ok !$client->status->age_verification, 'age verified not set correctly';
};

subtest 'verify identity by smile_identity is passed and DOB mismatch or underage' => sub {
    $args = {
        loginid => $client->loginid,
    };

    $idv_model->add_document({
        issuing_country => 'ke',
        number          => '12345',
        type            => 'national_id'
    });

    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth(Date::Utility->new->date);
    $client->save();

    _reset_submissions($client->binary_user_id);
    $client->status->clear_poi_name_mismatch;
    $client->status->setnx('age_verification', 'system');
    $updates = 0;

    $verification_status  = 'Verified';
    $personal_info_status = 'Returned';
    $personal_info        = {
        FullName => 'John Doe',
        DOB      => Date::Utility->new->date
    };

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    Actions => {
                        Verify_ID_Number     => $verification_status,
                        Return_Personal_Info => $personal_info_status,
                    },
                    $personal_info->%*,
                },
            )));

    ok $idv_event_handler->($args)->get, 'the event processed without error';
    is $updates, 2, 'update document triggered twice correctly';

    is $idv_model->submissions_left, 0, 'submissions reset to 0 correctly';
    ok !$client->status->poi_name_mismatch, 'poi_name_mismatch is not set correctly';
    ok !$client->status->age_verification,  'age verified removed correctly';

    $idv_model->add_document({
        issuing_country => 'ke',
        number          => '12345',
        type            => 'national_id'
    });

    _reset_submissions($client->binary_user_id);
    $client->status->clear_poi_name_mismatch;
    $client->status->set('age_verification', 'system');
    $updates = 0;

    $personal_info = {
        FullName => 'John Doe',
        DOB      => 'Not Available'
    };

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    Actions => {
                        Verify_ID_Number     => $verification_status,
                        Return_Personal_Info => $personal_info_status,
                    },
                    $personal_info->%*,
                },
            )));

    ok $idv_event_handler->($args)->get, 'the event processed without error';
    is $updates, 2, 'update document triggered twice correctly';

    is $idv_model->submissions_left, 0, 'submissions reset to 0 correctly';
    ok !$client->status->poi_name_mismatch, 'poi_name_mismatch is not set correctly';
    ok !$client->status->age_verification,  'age verified removed correctly';

    $client->date_of_birth('1999-10-30');
    $client->save();

    $idv_model->add_document({
        issuing_country => 'ke',
        number          => '12345',
        type            => 'national_id'
    });

    _reset_submissions($client->binary_user_id);
    $client->status->clear_poi_name_mismatch;
    $client->status->set('age_verification', 'system');
    $updates = 0;

    $personal_info = {
        FullName => 'John Doe',
        DOB      => '1999-10-31'
    };

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    Actions => {
                        Verify_ID_Number     => $verification_status,
                        Return_Personal_Info => $personal_info_status,
                    },
                    $personal_info->%*,
                },
            )));

    ok $idv_event_handler->($args)->get, 'the event processed without error';
    is $updates, 2, 'update document triggered twice correctly';

    is $idv_model->submissions_left, 0, 'submissions reset to 0 correctly';
    ok !$client->status->poi_name_mismatch, 'poi_name_mismatch is not set correctly';
    ok !$client->status->age_verification,  'age verified removed correctly';
};

subtest 'verification by smile_identity get failed with foul codes' => sub {
    $args = {
        loginid => $client->loginid,
    };

    $client->status->clear_poi_name_mismatch;
    $client->status->clear_age_verification;

    for my $code (qw/ 1022 1013 /) {
        _reset_submissions($client->binary_user_id);

        $resp = Future->done(
            HTTP::Response->new(
                200, undef, undef,
                encode_json_utf8({
                        ResultCode => $code,
                        $personal_info->%*,
                    },
                )));

        $updates = 0;

        $idv_model->add_document({
            issuing_country => 'ke',
            number          => $code,
            type            => 'national_id'
        });

        ok $idv_event_handler->($args)->get, 'the event processed without error';
        is $updates, 2, 'update document triggered twice correctly';
        is $idv_model->submissions_left, 0, 'submissions reset to 0 correctly';
        ok !$client->status->age_verification,  'no change in statuses: age_verification';
        ok !$client->status->poi_name_mismatch, 'no change in statuses: age_verification';
    }
};

sub _reset_submissions {
    my $user_id = shift;
    my $redis   = BOM::Config::Redis::redis_events();

    $redis->set(BOM::User::IdentityVerification::IDV_REQUEST_PER_USER_PREFIX . $user_id, 0);
}

done_testing();
