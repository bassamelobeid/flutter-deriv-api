use strict;
use warnings;

use Test::Most;
use JSON;
use Data::Dumper;
use BOM::Test::RPC::BomRpc;
use BOM::Test::Helper qw/build_wsapi_test/;
use Digest::SHA1 qw/sha1_hex/;

my $t = build_wsapi_test();

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

    $t->send_ok({json => $req})->message_ok;

    my $res = decode_json($t->message->[1]);

    warn Dumper $res;

    ok $res->{document_upload}, 'Returns document_upload';

    my $upload_id = $res->{document_upload}->{upload_id};
    my $call_type = $res->{document_upload}->{call_type};

    ok $upload_id, 'Returns upload_id';
    ok $call_type, 'Returns call_type';

    my $length = length $data;

    for (gen_frames $data, $call_type, $upload_id) {
        $t->send_ok({binary => $_});
    }
    $t->message_ok;

    $res = decode_json($t->message->[1]);
    warn Dumper $res;
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

document_upload_ok {
    document_upload => 1,
    document_id     => '12456',
    document_format => 'JPEG',
    document_type   => 'passport',
    expiry_date     => '12345',
    },
    'Hello world!';

document_upload_ok {
    document_upload => 1,
    document_id     => '124568',
    document_format => 'PNG',
    document_type   => 'license',
    expiry_date     => '12345',
    },
    'Goodbye!';

done_testing();
