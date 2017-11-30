use strict;
use warnings;

use Test::Most;
use Test::Warn;

no warnings qw/redefine/;

BEGIN {
    # Test should fail if Future DEBUG mode shows any warning
    $ENV{PERL_FUTURE_DEBUG} = 1;
}

use JSON::MaybeXS qw/decode_json encode_json/;
use BOM::Test::Helper qw/build_wsapi_test/;
use Digest::SHA qw/sha1_hex/;
use Net::Async::Webservice::S3;
use Variable::Disposition qw/retain_future/;

use Binary::WebSocketAPI::v3::Wrapper::DocumentUpload;
use Binary::WebSocketAPI::Hooks;
use BOM::Platform::User;
use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

use constant MAX_FILE_SIZE  => 2**20 * 3;    # 3MB
use constant MAX_CHUNK_SIZE => 2**17;

override_subs();

$ENV{DOCUMENT_AUTH_S3_ACCESS} = 'TestingS3Access';
$ENV{DOCUMENT_AUTH_S3_SECRET} = 'TestingS3Secret';
$ENV{DOCUMENT_AUTH_S3_BUCKET} = 'TestingS3Bucket';

my $t = build_wsapi_test();

my $email       = 'test-binary' . rand(999) . '@binary.com';
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
$test_client->email($email);
$test_client->save;

my $loginid = $test_client->loginid;
my $user    = BOM::Platform::User->create(
    email    => $email,
    password => '1234',
);
$user->add_loginid({loginid => $loginid});
$user->save;

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

$t = $t->send_ok({json => {authorize => $token}})->message_ok;

my $req_id      = 1;
my $CHUNK_SIZE  = 6;
my $PASSTHROUGH = {key => 'value'};

my $generic_req = {
    passthrough     => $PASSTHROUGH,
    document_upload => 1,
    document_id     => '12456',
    document_format => 'JPEG',
    document_type   => 'passport',
    expiration_date => '2020-01-01',
};

subtest 'Upload fail before the last chunk' => sub {
    my $data   = 'Some text';
    my $length = length $data;

    my $req = {
        %$generic_req,
        req_id      => ++$req_id,
        file_size   => $length,
    };

    my $c = get_c();

    $t = $t->send_ok({json => $req})->message_ok;
    my $res       = decode_json($t->message->[1]);
    my $upload_id = $res->{document_upload}->{upload_id};
    my $call_type = $res->{document_upload}->{call_type};

    my @frames = gen_frames($data, $call_type, $upload_id);

    receive_ok($upload_id, $data);
    $t = $t->send_ok({binary => $frames[0]});

    $c->stash->{document_upload}->{$upload_id}->{put_future}->fail('Ungracefully');

    $t   = $t->message_ok;
    $res = decode_json($t->message->[1]);

    my $error = $res->{error};

    is $error->{code}, 'UploadDenied', 'Upload should fail if put_object fails';
};

subtest 'Encoded json passed as binary frame' => sub {
    $t = $t->send_ok({binary => encode_json({ping => 1})})->message_ok;
    my $res = decode_json($t->message->[1]);

    ok $res->{ping}, 'Encoded json should be treated as json';
};

subtest 'Invalid upload frame' => sub {
    warning_like {
        $t = $t->send_ok({
                binary => (pack 'N', 1),
            })->message_ok;
    }
    [qr/Invalid frame/], 'Expected warning';
    my $res = decode_json($t->message->[1]);

    ok $res->{error}, 'Upload frame should be at least 12 bytes';
};

subtest 'Send binary data without requesting document_upload' => sub {
    warning_like {
        $t = $t->send_ok({
                binary => (pack 'N3A*', 1, 1, 1, 'A'),
            })->message_ok;
    }
    [qr/Unknown upload request/], 'Expected warning';

    my $res = decode_json($t->message->[1]);

    ok $res->{error}, 'Should ask for document_upload first';
};

subtest 'Invalid s3 config' => sub {
    my $data   = 'text';
    my $length = length $data;

    my $req = {
        %$generic_req,
        req_id      => ++$req_id,
        file_size   => $length,
    };

    # Valid bucket name to cause error
    $ENV{DOCUMENT_AUTH_S3_BUCKET} = 'ValidBucket';

    $t = $t->send_ok({json => $req})->message_ok;
    my $res       = decode_json($t->message->[1]);
    my $upload_id = $res->{document_upload}->{upload_id};
    my $call_type = $res->{document_upload}->{call_type};

    my @frames = gen_frames($data, $call_type, $upload_id);

    $t   = $t->send_ok({binary => $frames[0]});
    $t   = $t->message_ok;
    $res = decode_json($t->message->[1]);

    my $error = $res->{error};

    is $error->{code}, 'UploadDenied', 'Upload should fail for invalid s3 config';

    is $res->{req_id},             $req->{req_id},      'req_id is unchanged';
    is_deeply $res->{passthrough}, $req->{passthrough}, 'passthrough is unchanged';

# revert bucket name
    $ENV{DOCUMENT_AUTH_S3_BUCKET} = 'TestingS3Bucket';
};

subtest 'binary metadata should be correctly sent' => sub {
    my $req = {
        %$generic_req,
        req_id      => ++$req_id,
        file_size   => 1,
    };

    $t = $t->send_ok({json => $req})->message_ok;

    my $res = decode_json($t->message->[1]);

    ok $res->{document_upload}, 'Returns document_upload';

    my $upload_id = $res->{document_upload}->{upload_id};
    my $call_type = $res->{document_upload}->{call_type};

    warning_like {
        $t = $t->send_ok({
                binary => (pack 'N3A*', $call_type, 1111, 1, 'A'),
            })->message_ok;
    }
    [qr/Unknown upload request/], 'Expected warning';
    $res = decode_json($t->message->[1]);
    ok $res->{error}, 'upload_id should be valid';

    warning_like {
        $t = $t->send_ok({
                binary => (pack 'N3A*', 1111, $upload_id, 1, 'A'),
            })->message_ok;
    }
    [qr/Unknown call type/], 'Expected warning';
    $res = decode_json($t->message->[1]);
    ok $res->{error}, 'call_type should be valid';

    warning_like {
        $t = $t->send_ok({
                binary => (pack 'N3A*', $call_type, $upload_id, 2, 'A'),
            })->message_ok;
    }
    [qr/Incorrect chunk size/], 'Expected warning';
    $res = decode_json($t->message->[1]);
    ok $res->{error}, 'chunk_size should be valid';

    warning_like {
        $t = $t->send_ok({
                binary => (pack 'N3A*', $call_type, $upload_id, MAX_CHUNK_SIZE + 1, 'A'),
            })->message_ok;
    }
    [qr/Maximum chunk size exceeded/], 'Expected warning';
    $res = decode_json($t->message->[1]);
    ok $res->{error}, 'chunk_size should be less than max';

    ok((not exists($res->{echo_req}->{status})), 'status should not be present');
};

subtest 'sending two files concurrently' => sub {
    my $data   = 'Some text';
    my $length = length $data;

    my $req1 = {
        %$generic_req,
        req_id      => ++$req_id,
        file_size   => $length,
    };

    my $req2 = {%{$req1}, req_id => ++$req_id};

    $t = $t->send_ok({json => $req1})->message_ok;
    my $res1       = decode_json($t->message->[1]);
    my $upload_id1 = $res1->{document_upload}->{upload_id};
    my $call_type1 = $res1->{document_upload}->{call_type};

    $t = $t->send_ok({json => $req2})->message_ok;
    my $res2       = decode_json($t->message->[1]);
    my $upload_id2 = $res2->{document_upload}->{upload_id};
    my $call_type2 = $res2->{document_upload}->{call_type};

    my @frames1 = gen_frames($data, $call_type1, $upload_id1);
    my @frames2 = gen_frames($data, $call_type2, $upload_id2);

    receive_ok($upload_id1, $data);
    receive_ok($upload_id2, $data);
    $t = $t->send_ok({binary => $frames1[0]});
    $t = $t->send_ok({binary => $frames2[0]});
    $t = $t->send_ok({binary => $frames1[1]});
    $t = $t->send_ok({binary => $frames2[1]});
    $t = $t->send_ok({binary => $frames1[2]});

    $t    = $t->message_ok;
    $res1 = decode_json($t->message->[1]);

    $t = $t->send_ok({binary => $frames2[2]});

    $t    = $t->message_ok;
    $res2 = decode_json($t->message->[1]);

    my $success = $res1->{document_upload};
    is $success->{upload_id}, $upload_id1, 'upload id1 is correct';
    is $success->{call_type}, $call_type1, 'call_type1 is correct';

    $success = $res2->{document_upload};
    is $success->{upload_id}, $upload_id2, 'upload id2 is correct';
    is $success->{call_type}, $call_type2, 'call_type2 is correct';
};

subtest 'Send two files one by one' => sub {
    my $data   = 'Hello world!';
    my $length = length $data;

    document_upload_ok({
            %$generic_req,
            file_size => $length,
        },
        $data
    );

    $data   = 'Goodbye!';
    $length = length $data;

    document_upload_ok({
            document_upload => 1,
            document_format => 'PNG',
            document_type   => 'bankstatement',
            file_size       => $length,
        },
        'Goodbye!'
    );
};

subtest 'Maximum file size' => sub {
    my $max_size = MAX_FILE_SIZE + 1;

    my $req = {
        %$generic_req,
        req_id      => ++$req_id,
        file_size   => $max_size,
    };

    $t = $t->send_ok({json => $req})->message_ok;
    my $res = decode_json($t->message->[1]);
    ok $res->{error}, 'Error for max size';

    is $res->{req_id},             $req->{req_id},      'req_id is unchanged';
    is_deeply $res->{passthrough}, $req->{passthrough}, 'passthrough is unchanged';

    my $metadata = {
        document_upload => 1,
        document_id     => '124568',
        document_format => 'PNG',
        document_type   => 'driverslicense',
        file_size       => $max_size - 1,
        expiration_date => '2020-01-01',
    };

    my $file = pack "A$max_size", ' ';

    my $previous_chunk_size = $CHUNK_SIZE;
    $CHUNK_SIZE = 16 * 1024;
    my $error;
    warning_like {
        $error = upload_error($metadata, $file);
    }
    [qr/Unknown upload request/], 'Expected warning';
    $CHUNK_SIZE = $previous_chunk_size;

    is $error->{code}, 'UploadDenied', 'Upload should be failed';

# ignore extra chunk
    $t = $t->message_ok;
};

subtest 'Invalid document_format' => sub {
    my $req = {
        %$generic_req,
        req_id          => ++$req_id,
        file_size       => 1,
        document_format => 'INVALID',
    };

    $t = $t->send_ok({json => $req})->message_ok;
    my $res = decode_json($t->message->[1]);
    ok $res->{error}, 'Error for wrong document_format';

    is $res->{req_id},             $req->{req_id},      'req_id is unchanged';
    is_deeply $res->{passthrough}, $req->{passthrough}, 'passthrough is unchanged';
};

subtest 'sending extra data after EOF chunk' => sub {
    my $data = 'Some text is here';
    my $size = length $data;

    my $req = {
        %$generic_req,
        req_id      => ++$req_id,
        file_size   => $size,
    };

    $t = $t->send_ok({json => $req})->message_ok;

    my $res = decode_json($t->message->[1]);

    my $upload_id = $res->{document_upload}->{upload_id};
    my $call_type = $res->{document_upload}->{call_type};

    my $length = length $data;

    my @frames = gen_frames($data, $call_type, $upload_id);

    receive_ok($upload_id, $data);
    for (@frames) {
        $t = $t->send_ok({binary => $_});
    }
    $t = $t->message_ok;

    $res = decode_json($t->message->[1]);
    my $success = $res->{document_upload};

    ok $success, 'Document is successfully uploaded';

    warning_like {
        $t = $t->send_ok({binary => $frames[0]})->message_ok;
    }
    [qr/Unknown upload request/], 'Expected warning';
    $res = decode_json($t->message->[1]);

    ok $res->{error}, 'Document no longer exists';
};

sub gen_frames {
    my ($data, $call_type, $upload_id) = @_;
    my $format = 'N3a*';
    my @frames = map { pack $format, $call_type, $upload_id, length $_, $_ } (unpack "(a$CHUNK_SIZE)*", $data);
    push @frames, pack $format, $call_type, $upload_id, 0;
    return @frames;
}

sub upload_error {
    my ($metadata, $data) = @_;

    my $upload = upload($metadata, $data);
    my $res = $upload->{res};

    my $error = $res->{error};

    ok $error->{code}, 'Upload should be failed';

    return $error;
}

sub upload_ok {
    my ($metadata, $data) = @_;

    my $upload    = upload($metadata, $data, 1);
    my $res       = $upload->{res};
    my $req       = $upload->{req};
    my $upload_id = $upload->{upload_id};
    my $call_type = $upload->{call_type};
    my $success   = $res->{document_upload};

    is $success->{upload_id}, $upload_id, 'upload id is correct';
    is $success->{call_type}, $call_type, 'call_type is correct';

    is_deeply $res->{echo_req}, $req, 'echo_req should contain the original request';

    return $success;
}

sub upload {
    my ($metadata, $data, $check_receive) = @_;

    my $req = {
        req_id      => ++$req_id,
        %{$metadata}};

    $t = $t->send_ok({json => $req})->message_ok;

    my $res = decode_json($t->message->[1]);

    is $res->{req_id},             $req->{req_id},      'req_id is unchanged';
    is_deeply $res->{passthrough}, $req->{passthrough}, 'passthrough is unchanged';

    ok $res->{document_upload}, 'Returns document_upload';

    my $upload_id = $res->{document_upload}->{upload_id};
    my $call_type = $res->{document_upload}->{call_type};

    ok $upload_id, 'Returns upload_id';
    ok $call_type, 'Returns call_type';

    my $length = length $data;

    receive_ok($upload_id, $data);
    for (gen_frames $data, $call_type, $upload_id) {
        $t = $t->send_ok({binary => $_});
    }
    $t = $t->message_ok;

    is $res->{req_id},             $req->{req_id},      'binary payload req_id is unchanged';
    is_deeply $res->{passthrough}, $req->{passthrough}, 'binary payload passthrough is unchanged';

    return {
        req       => $req,
        res       => decode_json($t->message->[1]),
        upload_id => $upload_id,
        call_type => $call_type,
    };
}

sub document_upload_ok {
    my ($metadata, $file) = @_;

    my $success = upload_ok $metadata, $file;

    is $success->{status}, 'success', 'File is successfully uploaded';
    is $success->{size}, length $file, 'file size is correct';
    is $success->{checksum}, sha1_hex($file), 'checksum is correct';
}

sub override_subs {
    my $last_chunk_received = \&Binary::WebSocketAPI::v3::Wrapper::DocumentUpload::last_chunk_received;
    *Binary::WebSocketAPI::v3::Wrapper::DocumentUpload::last_chunk_received = sub {
        my ($c, $upload_info) = @_;

        $last_chunk_received->($c, $upload_info);

        $upload_info->{last_chunk_arrived}->done if $upload_info->{chunk_size} == 0;
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

sub get_c { my ($c) = values $t->app->active_connections; $c }

sub receive_ok {
    my ($upload_id, $data) = @_;

    my $c           = get_c();
    my $upload_info = $c->stash->{document_upload}->{$upload_id};

    retain_future(receive_loop($c, $upload_info, $data));
}

sub receive_loop {
    my ($c, $upload_info, $data) = @_;

    my $test_digest = $upload_info->{test_digest} //= Digest::SHA->new;
    $upload_info->{test_received_size} //= 0;
    my $pending_futures = $upload_info->{pending_futures};

    return Binary::WebSocketAPI::v3::Wrapper::DocumentUpload::add_upload_future($c, $pending_futures)->then(
        sub {
            my $msg  = shift;
            my $size = length $data;

            $test_digest->add($msg);
            $upload_info->{test_received_size} += length $msg;
            return receive_loop($c, $upload_info, $data) if $upload_info->{test_received_size} < $size;

            is $test_digest->hexdigest, sha1_hex($data), 'Data received correctly';

            return $upload_info->{last_chunk_arrived}->on_ready($upload_info->{put_future});
        });
}

done_testing();

package MockS3;

use base qw( IO::Async::Notifier );

sub put_object { shift->loop->new_future }
