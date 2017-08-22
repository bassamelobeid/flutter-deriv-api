use strict;
use warnings;

use Test::Most;
use JSON;
use BOM::Test::RPC::BomRpc;
use BOM::Test::Helper qw/build_wsapi_test/;
use Digest::SHA1 qw/sha1_hex/;

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

my $t = build_wsapi_test();

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, 'CR0021');

$t = $t->send_ok({json => {authorize => $token}})->message_ok;

my $req_id     = 1;
my $CHUNK_SIZE = 6;

sub gen_frames {
    my ($data, $call_type, $upload_id) = @_;
    my $format = 'N3a*';
    my @frames = map { pack $format, $call_type, $upload_id, length $_, $_ } (unpack "(a$CHUNK_SIZE)*", $data);
    push @frames, pack $format, $call_type, $upload_id, 0;
    return @frames;
}

sub upload_ok {
    my ($metadata, $data) = @_;

    my $req = {
        req_id => ++$req_id,
        %{$metadata}};

    $t = $t->send_ok({json => $req})->message_ok;

    my $res = decode_json($t->message->[1]);

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

    $res = decode_json($t->message->[1]);
    my $success = $res->{document_upload};

    is $success->{upload_id}, $upload_id, 'upload id is correct';
    is $success->{call_type}, $call_type, 'call_type is correct';

    return $success;
}

my $file = 'Hello world!';

sub document_upload_ok {
    my ($metadata, $file) = @_;

    my $success = upload_ok $metadata, $file;

    is $success->{status}, 'success', 'File is successfully uploaded';
    is $success->{size}, length $file, 'file size is correct';
    is $success->{checksum}, sha1_hex($file), 'checksum is correct';
}

subtest 'Send binary data without requesting document_upload' => sub {
    $t = $t->send_ok({binary => pack 'N3A*', 1, 1, 1, 'A'})
        ->message_ok;
    
    my $res = decode_json($t->message->[1]);

    ok $res->{error}, 'Should ask for document_upload first';
};

subtest 'binary metadata should be correctly sent' => sub {
    $t = $t->send_ok({json => {
            req_id => ++$req_id,
            document_upload => 1,
            document_id     => '12456',
            document_format => 'JPEG',
            document_type   => 'passport',
            expiration_date     => '2020-01-01',
        }})
        ->message_ok;
    
    my $res = decode_json($t->message->[1]);

    ok $res->{document_upload}, 'Returns document_upload';

    my $upload_id = $res->{document_upload}->{upload_id};
    my $call_type = $res->{document_upload}->{call_type};

    $t = $t->send_ok({binary => pack 'N3A*', 1111, $upload_id, 1, 'A'})
        ->message_ok;
    
    $res = decode_json($t->message->[1]);

    ok $res->{error}, 'call_type should be valid';

    $t = $t->send_ok({binary => pack 'N3A*', $call_type, 1111, 1, 'A'})
        ->message_ok;
    
    $res = decode_json($t->message->[1]);

    ok $res->{error}, 'upload_id should be valid';

    $t = $t->send_ok({binary => pack 'N3A*', $call_type, $upload_id, 2, 'A'})
        ->message_ok;
    
    $res = decode_json($t->message->[1]);

    ok $res->{error}, 'chunk_size should be valid';
};

subtest 'Send two files correctly' => sub {
    document_upload_ok {
        document_upload => 1,
        document_id     => '12456',
        document_format => 'JPEG',
        document_type   => 'passport',
        expiration_date     => '2020-01-01',
        },
        'Hello world!';

    document_upload_ok {
        document_upload => 1,
        document_id     => '124568',
        document_format => 'PNG',
        document_type   => 'license',
        expiration_date     => '2020-01-01',
        },
        'Goodbye!';
};

done_testing();
