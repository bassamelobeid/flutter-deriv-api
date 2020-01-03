use strict;
use warnings;

use Test::Most;
use Test::Warn;
use Test::MockTime qw(:all);

no warnings qw/redefine/;

BEGIN {
    # Test should fail if Future DEBUG mode shows any warning
    $ENV{PERL_FUTURE_DEBUG} = 1;
}

use JSON::MaybeXS qw/decode_json encode_json/;
use BOM::Test::Helper qw/build_wsapi_test create_test_user/;
use Digest::MD5 qw/md5_hex/;
use Net::Async::Webservice::S3;
use List::Util qw[min];

use Binary::WebSocketAPI::v3::Wrapper::DocumentUpload;
use Binary::WebSocketAPI::Hooks;
use BOM::User;
use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use await;

use constant MAX_FILE_SIZE  => 8 * 2**20;
use constant MAX_CHUNK_SIZE => 2**17;

override_subs();

$ENV{DOCUMENT_AUTH_S3_ACCESS} = 'TestingS3Access';
$ENV{DOCUMENT_AUTH_S3_SECRET} = 'TestingS3Secret';
$ENV{DOCUMENT_AUTH_S3_BUCKET} = 'TestingS3Bucket';

my $t = build_wsapi_test();
my ($c) = values %{$t->app->active_connections};

my $loginid = create_test_user;
my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
$t->await::authorize({authorize => $token});

my $req_id      = 1;
my $chunk_size  = 6;
my $PASSTHROUGH = {key => 'value'};

my %generic_req = (
    passthrough     => $PASSTHROUGH,
    document_upload => 1,
    document_id     => '12456',
    document_format => 'JPEG',
    document_type   => 'passport',
    expiration_date => Date::Utility->today()->plus_time_interval('1d')->date,
);

use constant {FAIL_TEST_DATA => 'Some text'};

subtest 'Fail during upload' => sub {
    my $data   = FAIL_TEST_DATA;
    my $length = length $data;

    my %upload_info = request_upload($data);

    my @frames = gen_frames($data, %upload_info);
    my $upload_id = $upload_info{upload_id};

    $t->send_ok({binary => $frames[0]});

    # let the above frame land before failing
    $c->loop->delay_future(after => 0.01)->on_ready(
        sub {
            $c->stash->{document_upload}->{$upload_id}->{put_future}->fail('Ungracefully');
        });

    my $res = get_response($t);

    is $res->{error}->{code}, 'UploadDenied', 'Upload should fail if put_object fails';
};

subtest 'Invalid s3 config' => sub {
    my $data   = 'text';
    my $length = length $data;

    # Valid bucket name to cause error
    $ENV{DOCUMENT_AUTH_S3_BUCKET} = 'ValidBucket';

    my %upload_info = request_upload($data);

    # revert bucket name
    $ENV{DOCUMENT_AUTH_S3_BUCKET} = 'TestingS3Bucket';

    my @frames = gen_frames($data, %upload_info);

    my $res   = await_binary($frames[0]);
    my $error = $res->{error};

    is $error->{code}, 'UploadDenied', 'Upload should fail for invalid s3 config';

    my $req = $upload_info{req};
    is $res->{req_id},             $req->{req_id},      'req_id is unchanged';
    is_deeply $res->{passthrough}, $req->{passthrough}, 'passthrough is unchanged';
};

subtest 'binary frame should be sent correctly' => sub {
    my $res = await_binary(encode_json({ping => 1}));
    ok $res->{ping}, 'Encoded json should be treated as json';

    $res = send_warning((pack 'N', 1), qr/Invalid frame/);
    ok $res->{error}, 'Upload frame should be at least 12 bytes';

    $res = send_warning((pack 'N3A*', 1, 1, 1, 'A'), qr/Unknown upload request/);
    ok $res->{error}, 'Should ask for document_upload first';

    my %upload_info = request_upload('N');

    my ($call_type, $upload_id) = @upload_info{qw/call_type upload_id/};

    send_warning((pack 'N3A*', $call_type, 1111, 1, 'A'), qr/Unknown upload request/);

    send_warning((pack 'N3A*', 1111, $upload_id, 1, 'A'), qr/Unknown call type/);

    send_warning((pack 'N3A*', $call_type, $upload_id, 2, 'A'), qr/Incorrect chunk size/);

    $res = send_warning((pack 'N3A*', $call_type, $upload_id, MAX_CHUNK_SIZE + 1, 'A'), qr/Maximum chunk size exceeded/);

    ok((not exists($res->{echo_req}->{status})), 'status should not be present');
};

subtest 'sending two files concurrently on a single connection' => sub {
    send_two_docs_at_once('Some tex1', 'Some tex2', $t, $t);
};

subtest 'sending two files concurrently on separate connections' => sub {
    my $t2 = build_wsapi_test();
    $t2->await::authorize({authorize => $token});
    send_two_docs_at_once('Some tex3', 'Some tex4', $t, $t2);
};

sub send_two_docs_at_once {
    my @data    = (shift, shift);
    my @ws_list = (shift, shift);
    # Note: this test is hardcoded to expect data of a certain length
    #   so change the contents of these strings, but not the length
    my @requests;
    for my $i (0 .. 1) {
        my $ws = $ws_list[$i];
        my ($conn) = values %{$ws->app->active_connections};
        $requests[$i]->{ws} = $ws;

        my $upload_info = {request_upload($data[$i], undef, $ws)};
        receive_ok($data[$i], $upload_info, $conn);
        $requests[$i]->{upload_info} = $upload_info;
        $requests[$i]->{frames} = [gen_frames($data[$i], %$upload_info)];
    }

    $_->{ws}->send_ok({binary => $_->{frames}->[0]}) for @requests;
    $_->{ws}->send_ok({binary => $_->{frames}->[1]}) for @requests;
    @requests = map {
        { %$_, response => await_binary($_->{frames}->[2], $_->{ws}) }
    } @requests;

    for my $request (@requests) {
        my ($call_type, $upload_id) = @{$request->{upload_info}}{qw/call_type upload_id/};
        my $success = $request->{response}->{document_upload};
        is $success->{upload_id}, $upload_id, 'upload id is correct';
        is $success->{call_type}, $call_type, 'call_type is correct';
    }
}

subtest 'Checking filename' => sub {
    my %upload_info = request_upload(
        '',
        {
            document_type   => 'bankstatement',
            document_format => 'JPG',
            page_type       => 'back',
        });
    my $upload_id = $upload_info{upload_id};

    my $stashed_upload_info = $c->stash('document_upload')->{$upload_id};

    my ($file_id, $file_name) = @$stashed_upload_info{qw/file_id file_name/};

    my $expected_file_name = "$loginid.bankstatement.${file_id}_back.JPG";

    is $file_name, $expected_file_name, 'file name is correct';
};

subtest 'Send two files one by one' => sub {
    my %to_send = (
        'Hello world!' => {
            document_format => 'JPG',
            document_type   => 'driverslicense',
        },
        'Goodbye!' => {
            document_format => 'PNG',
            document_type   => 'bankstatement',
        },
    );

    document_upload_ok($_, %{$to_send{$_}}, file_size => length $_) for keys %to_send;
};

subtest 'Maximum file size' => sub {
    my $size = MAX_FILE_SIZE + 1;

    my $previous_chunk_size = $chunk_size;
    $chunk_size = 16 * 1024;

    my %upload_info = upload_error((pack "A$size", ' '), qr/Unknown upload request/);

    my $error = $upload_info{res}->{error};
    is $error->{code}, 'UploadDenied', 'Upload should be failed';

    $chunk_size = $previous_chunk_size;

    # ignore extra chunk
    $t->message_ok();
};

subtest 'Invalid document_format' => sub {
    my $req = {
        %generic_req,
        req_id            => ++$req_id,
        file_size         => 1,
        document_format   => 'INVALID',
        expected_checksum => 'INVALID',
    };

    my $res = $t->await::document_upload($req);
    ok $res->{error}, 'Error for wrong document_format';

    is $res->{req_id},             $req->{req_id},      'req_id is unchanged';
    is_deeply $res->{passthrough}, $req->{passthrough}, 'passthrough is unchanged';
};

subtest 'sending extra data after EOF chunk' => sub {
    my $data   = 'Some text is here';
    my $length = length $data;

    my %upload_info = document_upload_ok($data, file_size => $length);

    my @frames = gen_frames($data, %upload_info);

    send_warning($frames[$#frames], qr/Unknown upload request/);
};

subtest 'Checksum not matching the etag' => sub {
    my $data   = 'Some more text is here';
    my $length = length $data;

    my %upload_info = request_upload($data);

    receive_ok($data, \%upload_info);
    my @frames = gen_frames($data, %upload_info);

    my $res;
    warning_like {
        for my $i (0 .. $#frames) {
            my $upload_id = $upload_info{upload_id};
            $t->send_ok({binary => $frames[$i]});
            # Make the etag incorrect
            $c->stash->{document_upload}->{$upload_id}->{test_digest}->reset if $i == $#frames - 1;
        }
        $res = get_response($t);
    }
    [qr/S3 etag does not match the checksum/], 'Expected warning';

    my $error = $res->{error};
    ok $error->{code}, 'Upload should be failed for incorrect checksum';
};

subtest 'Duplicate upload rejected' => sub {
    # First upload
    my $data        = 'File';
    my $length      = length $data;
    my %upload_info = document_upload_ok($data, file_size => $length);

    # Request to upload the same file again
    my $req = {
        %generic_req,
        req_id            => ++$req_id,
        expected_checksum => md5_hex($data),
        file_size         => min(length $data, MAX_FILE_SIZE),
    };
    my $res = $t->await::document_upload($req);

    is $res->{error}->{code},    'DuplicateUpload',            'Error code for duplicate document';
    is $res->{error}->{message}, 'Document already uploaded.', 'Error msg for duplicate document';
};

subtest 'Document with wrong checksum rejected' => sub {
    my $data       = 'This is the expected text';
    my $other_data = 'This is not expected text';
    my $length     = length $data;
    my $checksum   = md5_hex($data);

    my %upload_info = request_upload($data);

    receive_ok($other_data, \%upload_info);
    my @frames = gen_frames($other_data, %upload_info);

    my $res;
    for my $i (0 .. $#frames) {
        my $upload_id = $upload_info{upload_id};
        $t->send_ok({binary => $frames[$i]});
    }
    $res = get_response($t);

    my $error = $res->{error};
    is $error->{code}, 'ChecksumMismatch', 'Error code for checksum fail';
    is $error->{message}, 'Checksum verification failed.', 'Error msg for checksum fail';
};

subtest 'Attempt to re-upload document after error uploading' => sub {
    # Re-attempt the data that failed in the first subtest: 'Fail during upload'
    my $data   = FAIL_TEST_DATA;
    my $length = length $data;
    document_upload_ok($data, file_size => $length);
};

subtest 'Attempt to restart a timed out upload' => sub {
    my $data   = 'Timeout data';
    my $length = length $data;

    my $request     = {};
    my $upload_info = {request_upload($data)};
    receive_ok($data, $upload_info);
    $request->{upload_info} = $upload_info;
    $request->{frames} = [gen_frames($data, %$upload_info)];

    $t->send_ok({binary => $request->{frames}->[0]});

    # Send a frame, then stop, let server timeout, try again
    set_relative_time(120);

    document_upload_ok($data, file_size => $length);
};

sub gen_frames {
    my ($data,      %upload_info) = @_;
    my ($call_type, $upload_id)   = @upload_info{qw/call_type upload_id/};
    my $format = 'N3a*';
    my @frames = map { pack $format, $call_type, $upload_id, length $_, $_ } (unpack "(a$chunk_size)*", $data);
    push @frames, pack $format, $call_type, $upload_id, 0;
    return @frames;
}

sub upload_error {
    my ($data, $warning, %metadata) = @_;

    my %upload_info = request_upload($data, \%metadata);

    my $res;
    warning_like {
        $res = send_chunks($data, %upload_info);
    }
    [$warning], 'Expected warning';

    my $error = $res->{error};

    ok $error->{code}, 'Upload should be failed';

    return (
        %upload_info,
        res => $res,
    );
}

sub upload_ok {
    my ($data, %metadata) = @_;

    my %upload_info = upload($data, %metadata);

    my ($call_type, $upload_id, $req, $res) = @upload_info{qw/call_type upload_id req res/};
    my $success = $res->{document_upload};

    is $success->{upload_id},   $upload_id, 'upload id is correct';
    is $success->{call_type},   $call_type, 'call_type is correct';
    is_deeply $res->{echo_req}, $req,       'echo_req should contain the original request';

    return %upload_info;
}

sub request_upload {
    my ($data, $metadata, $ws) = @_;
    $ws //= $t;
    $metadata //= {};
    my $req = {
        %generic_req, %$metadata,
        req_id            => ++$req_id,
        expected_checksum => md5_hex($data),
        file_size         => min(length $data, MAX_FILE_SIZE),
        # The min is necessary to handle the special case for test 'Maximum file size'
        #   which sends frames in excess of the maximum allowed file size, but needs
        #   to spoof the size so the upload isn't disallowed at the start.
    };
    my $res = $ws->await::document_upload($req);
    is $res->{error}, undef, 'No error in response' or diag explain $res->{error};
    is $res->{req_id},             $req->{req_id},      'req_id is unchanged';
    is_deeply $res->{passthrough}, $req->{passthrough}, 'passthrough is unchanged';
    ok $res->{document_upload},    'Returns document_upload (for none-duplicate files)';

    my $upload_id = $res->{document_upload} ? $res->{document_upload}->{upload_id} : undef;
    my $call_type = $res->{document_upload} ? $res->{document_upload}->{call_type} : undef;

    ok $upload_id, 'Returns upload_id';
    ok $call_type, 'Returns call_type';
    return (
        call_type => $call_type,
        upload_id => $upload_id,
        req       => $req,
    );
}

sub upload {
    my ($data, %metadata) = @_;

    my %upload_info = request_upload($data, \%metadata);

    my $res = send_chunks($data, %upload_info);
    my $req = $upload_info{req};

    is $res->{req_id},             $req->{req_id},      'binary payload req_id is unchanged';
    is_deeply $res->{passthrough}, $req->{passthrough}, 'binary payload passthrough is unchanged';

    return (
        %upload_info,
        res => $res,
    );
}

sub send_chunks {
    my ($data, %upload_info) = @_;

    my $length = length $data;

    receive_ok($data, \%upload_info);
    for (gen_frames($data, %upload_info)) {
        $t->send_ok({binary => $_});
    }

    return get_response($t);
}

sub document_upload_ok {
    my ($data, %metadata) = @_;

    my %upload_info = upload_ok($data, %metadata);

    my $success = $upload_info{res}->{document_upload};

    is $success->{status}, 'success', 'File is successfully uploaded';
    is $success->{size}, length $data, 'file size is correct';
    is $success->{checksum}, md5_hex($data), 'checksum is correct';

    return %upload_info;
}

sub override_subs {
    my $last_chunk_received = \&Binary::WebSocketAPI::v3::Wrapper::DocumentUpload::last_chunk_received;
    *Binary::WebSocketAPI::v3::Wrapper::DocumentUpload::last_chunk_received = sub {
        my ($c, $upload_info) = @_;

        $upload_info->{last_chunk_arrived}->done if $upload_info->{chunk_size} == 0;

        return $last_chunk_received->($c, $upload_info);
    };

    my $create_s3_instance = \&Binary::WebSocketAPI::v3::Wrapper::DocumentUpload::create_s3_instance;
    *Binary::WebSocketAPI::v3::Wrapper::DocumentUpload::create_s3_instance = sub {
        my ($c, $upload_info) = @_;

        $upload_info->{last_chunk_arrived} = $c->loop->new_future;

        return $create_s3_instance->($c, $upload_info) unless $ENV{DOCUMENT_AUTH_S3_BUCKET} eq 'TestingS3Bucket';

        my $s3 = MockS3->new;

        $c->loop->add($s3);

        return $upload_info->{s3} = $s3;
    };

    my $clean_up_on_finish = \&Binary::WebSocketAPI::v3::Wrapper::DocumentUpload::clean_up_on_finish;
    *Binary::WebSocketAPI::v3::Wrapper::DocumentUpload::clean_up_on_finish = sub {
        my ($c, $upload_info) = @_;

        $clean_up_on_finish->($c, $upload_info);

        return unless exists $upload_info->{last_chunk_arrived};

        $upload_info->{last_chunk_arrived}->cancel;
    };
}

sub receive_ok {
    my ($data, $upload_request_info, $conn) = @_;
    $conn //= $c;

    my $upload_id   = $upload_request_info->{upload_id};
    my $upload_info = $conn->stash->{document_upload}->{$upload_id};

    receive_loop($data, $upload_info, $conn)->retain;
}

sub receive_loop {
    my ($data, $upload_info, $conn) = @_;
    $conn //= $c;

    my $test_digest = $upload_info->{test_digest} //= Digest::MD5->new;
    $upload_info->{test_received_size} //= 0;
    my $pending_futures = $upload_info->{pending_futures};

    return Binary::WebSocketAPI::v3::Wrapper::DocumentUpload::wait_for_chunk($conn, $pending_futures)->then(
        sub {
            my $msg  = shift;
            my $size = length $data;

            $test_digest->add($msg);
            $upload_info->{test_received_size} += length $msg;
            return receive_loop($data, $upload_info) if $upload_info->{test_received_size} < $size;

            return $upload_info->{last_chunk_arrived}->on_done(
                sub {
                    $upload_info->{put_future}->done($test_digest->hexdigest, $upload_info->{test_received_size});
                });
        });
}

sub send_warning {
    my ($frame, $warning) = @_;

    my $res;
    warning_like {
        $res = await_binary($frame);
    }
    [$warning], 'Expected warning';

    return $res;
}

sub await_binary {
    my ($frame, $ws) = @_;
    $ws //= $t;
    get_response($ws->send_ok({binary => $frame}));
}

sub get_response { decode_json(shift->message_ok->message->[1]) }

done_testing();

package MockS3;

use base qw( IO::Async::Notifier );

sub put_object { shift->loop->new_future }
