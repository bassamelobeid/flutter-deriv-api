use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;

use Date::Utility;
use Future::Exception;
use HTTP::Response;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);

use BOM::Config::Redis;
use BOM::Event::Process;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User::IdentityVerification;
use BOM::Test::Email;

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

# Don't use microservice
my $mock_idv_event_action = Test::MockModule->new('BOM::Event::Actions::Client::IdentityVerification');
$mock_idv_event_action->mock('_is_microservice_available', 0);

my $mock_services = Test::MockModule->new('BOM::Event::Services');
my $http_idv      = 0;
my $http          = 0;

$mock_services->mock(
    'http_idv',
    sub {
        $http_idv++;
        return $mock_services->original('http_idv')->(@_);
    });
$mock_services->mock(
    'http',
    sub {
        $http++;
        return $mock_services->original('http')->(@_);
    });

my $mock_idv_model = Test::MockModule->new('BOM::User::IdentityVerification');
my $mock_idv_status;
$mock_idv_model->redefine(
    update_document_check => sub {
        $updates++;
        my ($idv, $args) = @_;
        $mock_idv_status = $args->{status};
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

my $lifetime_valid = 0;
my $document_type  = undef;
$mock_country_configs->redefine(
    get_idv_config => sub {
        my $config = $mock_country_configs->original('get_idv_config')->(@_);

        $config->{document_types}->{$document_type}->{lifetime_valid} = $lifetime_valid;

        return $config;
    });

my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);

my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

my (@identify_args, @track_args);
my $segment_response = Future->done(1);
my $mock_segment     = new Test::MockModule('WebService::Async::Segment::Customer');
$mock_segment->redefine(
    'identify' => sub {
        @identify_args = @_;
        return $segment_response;
    },
    'track' => sub {
        @track_args = @_;
        return $segment_response;
    });

subtest 'verify identity by smile_identity is passed and data are valid' => sub {
    undef @identify_args;
    undef @track_args;
    $http_idv = 0;
    $http     = 0;

    $args = {
        loginid => $client->loginid,
    };

    $updates = 0;

    $idv_model->add_document({
        issuing_country => 'ke',
        number          => '12345',
        type            => $document_type = 'national_id'
    });
    $lifetime_valid = 1;

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
        DOB      => '1999-10-31',
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

    is $mock_idv_status, 'verified', 'verify_identity returns `verified` status';
    is @identify_args, 0, 'Segment identify is not called on `verified` status';
    is @track_args,    0, 'Segment track is not called `verified` status';

    is $http_idv, 1, 'Http idv called once';
    is $http,     0, 'Standalone http not used';
};

subtest 'verify identity by smile_identity is passed but document is expired' => sub {
    undef @identify_args;
    undef @track_args;
    $http_idv = 0;
    $http     = 0;

    $client->status->clear_poi_name_mismatch;
    $client->status->clear_age_verification;
    $args = {
        loginid => $client->loginid,
    };

    $idv_model->add_document({
        issuing_country => 'gh',
        number          => '12345',
        type            => $document_type = 'drivers_license'
    });
    $lifetime_valid = 0;

    _reset_submissions($client->binary_user_id);

    $client->status->set('age_verification', 'system');
    $updates = 0;

    $verification_status  = 'Verified';
    $personal_info_status = 'Returned';
    $personal_info        = {ExpirationDate => Date::Utility->new->_minus_months(1)->date_yyyymmdd};

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

    is $idv_model->submissions_left, 1, 'submissions not reset';
    ok !$client->status->poi_name_mismatch, 'poi_name_mismatch is not set correctly';
    ok !$client->status->age_verification,  'age verified removed correctly';

    is $mock_idv_status, 'refuted', 'verify_identity returns `refuted` status';
    is @identify_args, 0, 'Segment identify is not called on `refuted` status';
    ok @track_args, 'Segment track is called on `refuted` status';

    is $http_idv, 1, 'Http idv called once';
    is $http,     0, 'Standalone http not used';

    undef @identify_args;
    undef @track_args;
    $http_idv = 0;
    $http     = 0;

    $idv_model->add_document({
        issuing_country => 'ke',
        number          => '12345',
        type            => $document_type = 'national_id'
    });
    $lifetime_valid = 0;

    $updates = 0;

    $personal_info = {
        ExpirationDate => "Not Available",
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

    is $idv_model->submissions_left, 0, 'submissions left are finished';
    ok !$client->status->poi_name_mismatch, 'poi_name_mismatch is not set correctly';
    ok !$client->status->age_verification,  'age verified is not changed correctly';

    is $mock_idv_status, 'refuted', 'verify_identity returns `refuted` status';
    is @identify_args, 0, 'Segment identify is not called on `refuted` status';
    ok @track_args, 'Segment track is called on `refuted` status';

    is $http_idv, 1, 'Http idv called once';
    is $http,     0, 'Standalone http not used';
};

subtest 'verify identity by smile_identity is passed but document expiration date is unknown but document is lifetime valid' => sub {
    undef @identify_args;
    undef @track_args;
    $http_idv = 0;
    $http     = 0;

    $client->status->clear_poi_name_mismatch;
    $client->status->clear_age_verification;

    $args = {
        loginid => $client->loginid,
    };

    $idv_model->add_document({
        issuing_country => 'ke',
        number          => '12345',
        type            => $document_type = 'national_id'
    });
    $lifetime_valid = 1;

    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1999-10-31');
    $client->save();

    _reset_submissions($client->binary_user_id);

    $client->status->set('poi_name_mismatch');
    $updates = 0;

    $verification_status  = 'Verified';
    $personal_info_status = 'Returned';
    $personal_info        = {
        FullName       => 'John Doe',
        DOB            => '1999-10-31',
        ExpirationDate => 'Unknown date',
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

    is $idv_model->submissions_left, 1, 'submissions not reset';
    ok !$client->status->poi_name_mismatch, 'poi_name_mismatch is not set correctly';
    ok $client->status->age_verification, 'age verified correctly';

    is $mock_idv_status, 'verified', 'verify_identity returns `verified` status';
    is @identify_args, 0, 'Segment identify is not called on `verified` status';
    is @track_args,    0, 'Segment track is not called `verified` status';

    is $http_idv, 1, 'Http idv called once';
    is $http,     0, 'Standalone http not used';
};

subtest 'verify identity by smile_identity is passed and name mismatched' => sub {
    undef @identify_args;
    undef @track_args;
    $http_idv = 0;
    $http     = 0;

    $args = {
        loginid => $client->loginid,
    };

    $updates = 0;

    $idv_model->add_document({
        issuing_country => 'ke',
        number          => '12345',
        type            => $document_type = 'national_id'
    });
    $lifetime_valid = 1;

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

    is $mock_idv_status, 'refuted', 'verify_identity returns `refuted` status';
    is @identify_args, 0, 'Segment identify is not called on `refuted` status';
    ok @track_args, 'Segment track is called on `refuted` status';

    is $http_idv, 1, 'Http idv called once';
    is $http,     0, 'Standalone http not used';

    undef @identify_args;
    undef @track_args;
    $http_idv = 0;
    $http     = 0;

    $idv_model->add_document({
        issuing_country => 'ke',
        number          => '12345',
        type            => $document_type = 'national_id'
    });
    $lifetime_valid = 1;

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

    is $mock_idv_status, 'refuted', 'verify_identity returns `refuted` status';
    is @identify_args, 0, 'Segment identify is not called on `refuted` status';
    ok @track_args, 'Segment track is called on `refuted` status';

    is $http_idv, 1, 'Http idv called once';
    is $http,     0, 'Standalone http not used';

    my $doc = $idv_model->get_last_updated_document();
    cmp_bag decode_json_utf8($doc->{status_messages}), [qw/NAME_MISMATCH UNDERAGE DOB_MISMATCH/], 'Expected status message';
};

subtest 'verify identity by smile_identity is passed and DOB mismatch or underage' => sub {
    undef @identify_args;
    undef @track_args;
    $http_idv = 0;
    $http     = 0;

    $args = {
        loginid => $client->loginid,
    };

    $idv_model->add_document({
        issuing_country => 'ke',
        number          => '12345',
        type            => $document_type = 'national_id'
    });
    $lifetime_valid = 1;

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
                    trash      => 1,
                    garbage    => 2,
                    SmileJobID => '999',
                    $personal_info->%*,
                },
            )));

    my $doc = $idv_model->get_last_updated_document();
    my $chk = $idv_model->get_document_check_detail($doc->{id});

    my $response = decode_json_utf8($chk->{response});

    cmp_bag [keys $response->%*], [qw/ResultCode Actions ExpirationDate DOB FullName SmileJobID/], 'Expected keys stored';

    ok $idv_event_handler->($args)->get, 'the event processed without error';
    is $updates, 2, 'update document triggered twice correctly';

    is $idv_model->submissions_left, 0, 'submissions reset to 0 correctly';
    ok !$client->status->poi_name_mismatch, 'poi_name_mismatch is not set correctly';
    ok !$client->status->age_verification,  'age verified removed correctly';

    is $mock_idv_status, 'refuted', 'verify_identity returns `refuted` status';
    is @identify_args, 0, 'Segment identify is not called on `refuted` status';
    ok @track_args, 'Segment track is called on `refuted` status';

    is $http_idv, 1, 'Http idv called once';
    is $http,     0, 'Standalone http not used';

    undef @identify_args;
    undef @track_args;
    $http_idv = 0;
    $http     = 0;

    $idv_model->add_document({
        issuing_country => 'ke',
        number          => '12345',
        type            => $document_type = 'national_id'
    });
    $lifetime_valid = 1;

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

    mailbox_clear();
    ok $idv_event_handler->($args)->get, 'the event processed without error';
    is $updates, 2, 'update document triggered twice correctly';

    my $msg = mailbox_search(subject => qr/Underage client detection/);

    ok $msg, 'underage email not sent CS';

    is $idv_model->submissions_left, 0, 'submissions reset to 0 correctly';
    ok !$client->status->poi_name_mismatch, 'poi_name_mismatch is not set correctly';
    ok !$client->status->age_verification,  'age verified removed correctly';

    $client->date_of_birth('1999-10-30');
    $client->save();

    $idv_model->add_document({
        issuing_country => 'ke',
        number          => '12345',
        type            => $document_type = 'national_id'
    });
    $lifetime_valid = 1;

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

    $http_idv = 0;
    $http     = 0;

    ok $idv_event_handler->($args)->get, 'the event processed without error';
    is $updates, 2, 'update document triggered twice correctly';

    is $idv_model->submissions_left, 0, 'submissions reset to 0 correctly';
    ok !$client->status->poi_name_mismatch, 'poi_name_mismatch is not set correctly';
    ok !$client->status->age_verification,  'age verified removed correctly';

    is $mock_idv_status, 'refuted', 'verify_identity returns `refuted` status';
    is @identify_args, 0, 'Segment identify is not called on `refuted` status';
    ok @track_args, 'Segment track is called on `refuted` status';

    is $http_idv, 1, 'Http idv called once';
    is $http,     0, 'Standalone http not used';
};

subtest 'verification by smile_identity get failed with foul codes' => sub {
    $args = {
        loginid => $client->loginid,
    };

    $client->status->clear_poi_name_mismatch;
    $client->status->clear_age_verification;

    for my $code (qw/ 1022 1013 /) {
        undef @identify_args;
        undef @track_args;
        $http_idv = 0;
        $http     = 0;

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
            type            => $document_type = 'national_id'
        });
        $lifetime_valid = 1;

        ok $idv_event_handler->($args)->get, 'the event processed without error';
        is $updates, 2, 'update document triggered twice correctly';
        is $idv_model->submissions_left, 0, 'submissions reset to 0 correctly';
        ok !$client->status->age_verification,  'no change in statuses: age_verification';
        ok !$client->status->poi_name_mismatch, 'no change in statuses: age_verification';

        is $mock_idv_status, 'failed', 'verify_identity returns `failed` status';
        is @identify_args, 0, 'Segment identify is not called on `unavailable` status';
        is @track_args,    0, 'Segment track is not called `unavailable` status';

        is $http_idv, 1, 'Http idv called once';
        is $http,     0, 'Standalone http not used';
    }
};

$mock_segment->unmock_all;
$mock_services->unmock_all;

sub _reset_submissions {
    my $user_id = shift;
    my $redis   = BOM::Config::Redis::redis_events();

    $redis->set(BOM::User::IdentityVerification::IDV_REQUEST_PER_USER_PREFIX . $user_id, 0);
}

done_testing();
