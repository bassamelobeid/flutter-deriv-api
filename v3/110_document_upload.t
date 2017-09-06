use strict;
use warnings;

use Test::Most;
use Test::Warn;
use JSON;
use BOM::Test::Helper qw/build_wsapi_test/;
use Digest::SHA1 qw/sha1_hex/;

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

my $t = build_wsapi_test();

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, 'CR0021');

$t = $t->send_ok({json => {authorize => $token}})->message_ok;

my $req_id      = 1;
my $CHUNK_SIZE  = 6;
my $PASSTHROUGH = {key => 'value'};

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

subtest 'binary metadata should be correctly sent' => sub {
    my $req = {
        req_id          => ++$req_id,
        passthrough     => $PASSTHROUGH,
        document_upload => 1,
        document_id     => '12456',
        document_format => 'JPEG',
        document_type   => 'passport',
        expiration_date => '2020-01-01',
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
    [qr/Unknown upload id/], 'Expected warning';
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
    [qr/Incorrect data size/], 'Expected warning';
    $res = decode_json($t->message->[1]);
    ok $res->{error}, 'chunk_size should be valid';

    ok(not $res->{echo_req}->{status}), 'status should not be present';
};

subtest 'sending two files concurrently' => sub {
    my $req1 = {
        req_id          => ++$req_id,
        passthrough     => $PASSTHROUGH,
        document_upload => 1,
        document_id     => '12456',
        document_format => 'JPEG',
        document_type   => 'passport',
        expiration_date => '2020-01-01',
    };

    my $req2 = {
        req_id          => ++$req_id,
        passthrough     => $PASSTHROUGH,
        document_upload => 1,
        document_id     => '12456',
        document_format => 'JPEG',
        document_type   => 'passport',
        expiration_date => '2022-01-01',
    };

    my $data = 'Some text';

    $t = $t->send_ok({json => $req1})->message_ok;
    my $res1       = decode_json($t->message->[1]);
    my $upload_id1 = $res1->{document_upload}->{upload_id};
    my $call_type1 = $res1->{document_upload}->{call_type};

    $t = $t->send_ok({json => $req2})->message_ok;
    my $res2       = decode_json($t->message->[1]);
    my $upload_id2 = $res2->{document_upload}->{upload_id};
    my $call_type2 = $res2->{document_upload}->{call_type};

    my $length = length $data;

    my @frames1 = gen_frames($data, $call_type1, $upload_id1);
    my @frames2 = gen_frames($data, $call_type2, $upload_id2);

    $t = $t->send_ok({binary => $frames1[0]});
    $t = $t->send_ok({binary => $frames2[0]});
    $t = $t->send_ok({binary => $frames1[1]});
    $t = $t->send_ok({binary => $frames2[1]});
    $t = $t->send_ok({binary => $frames1[2]})->message_ok;
    $res1 = decode_json($t->message->[1]);
    $t    = $t->send_ok({binary => $frames2[2]})->message_ok;
    $res2 = decode_json($t->message->[1]);

    my $success = $res1->{document_upload};
    is $success->{upload_id}, $upload_id1, 'upload id1 is correct';
    is $success->{call_type}, $call_type1, 'call_type1 is correct';

    $success = $res2->{document_upload};
    is $success->{upload_id}, $upload_id2, 'upload id2 is correct';
    is $success->{call_type}, $call_type2, 'call_type2 is correct';
};

subtest 'Send two files one by one' => sub {
    document_upload_ok({
            document_upload => 1,
            document_id     => '12456',
            document_format => 'JPEG',
            document_type   => 'passport',
            expiration_date => '2020-01-01',
        },
        'Hello world!'
    );

    document_upload_ok({
            document_upload => 1,
            document_id     => '124568',
            document_format => 'PNG',
            document_type   => 'license',
            expiration_date => '2020-01-01',
        },
        'Goodbye!'
    );
};

subtest 'Maximum file size' => sub {
    my $max_size = 2**20 * 3 + 1;

    my $metadata = {
        document_upload => 1,
        document_id     => '124568',
        document_format => 'PNG',
        document_type   => 'license',
        expiration_date => '2020-01-01',
    };

    my $file = pack "A$max_size", ' ';

    my $previous_chunk_size = $CHUNK_SIZE;
    $CHUNK_SIZE = 16 * 1024;
    my $error = upload_error($metadata, $file);
    $CHUNK_SIZE = $previous_chunk_size;

    is $error->{code}, 'UploadError', 'Upload should be failed';
};

subtest 'Invalid document_format' => sub {
    my $req = {
        req_id          => ++$req_id,
        passthrough     => $PASSTHROUGH,
        document_upload => 1,
        document_id     => '12456',
        document_format => 'INVALID',
        document_type   => 'passport',
        expiration_date => '2020-01-01',
    };

    $t = $t->send_ok({json => $req})->message_ok;
    my $res = decode_json($t->message->[1]);
    ok $res->{error}, 'Error for wrong document_format';
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

    my $upload    = upload($metadata, $data);
    my $res       = $upload->{res};
    my $upload_id = $upload->{upload_id};
    my $call_type = $upload->{call_type};
    my $success   = $res->{document_upload};

    is $success->{upload_id}, $upload_id, 'upload id is correct';
    is $success->{call_type}, $call_type, 'call_type is correct';

    ok(not $res->{echo_req}->{status}), 'status should not be present';

    return $success;
}

sub upload {
    my ($metadata, $data) = @_;

    my $req = {
        req_id      => ++$req_id,
        passthrough => $PASSTHROUGH,
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

    for (gen_frames $data, $call_type, $upload_id) {
        $t = $t->send_ok({binary => $_});
    }
    $t = $t->message_ok;

    is $res->{req_id},             $req->{req_id},      'binary payload req_id is unchanged';
    is_deeply $res->{passthrough}, $req->{passthrough}, 'binary payload passthrough is unchanged';

    return {
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

done_testing();
