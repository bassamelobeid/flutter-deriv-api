use strict;
use warnings;

use Test::Most;
use JSON;
use Data::Dumper;
use BOM::Test::RPC::BomRpc;
use BOM::Test::Helper qw/build_wsapi_test/;
use Digest::SHA1 qw/sha1_hex/;

my $t = build_wsapi_test();

my $req = {
    document_upload => 1,
    document_id     => '12456',
    document_format => 'JPEG',
    document_type   => 'passport',
    req_id          => 10,
    expiry_date     => '12345',
};

$t->send_ok({json => $req})->message_ok;

my $res = decode_json($t->message->[1]);

ok $res->{document_upload}, 'Returns document_upload';

my $upload_id = $res->{document_upload}->{upload_id};
my $call_type = $res->{document_upload}->{call_type};

ok $upload_id, 'Returns upload_id';
ok $call_type, 'Returns call_type';

my $chunk1 = pack 'N N N A*', 1, $upload_id, 6, 'Hello ';
my $chunk2 = pack 'N N N A*', 1, $upload_id, 5, 'World';
my $chunk3 = pack 'N N N A*', 1, $upload_id, 0;

$t->send_ok({binary => $chunk1})->send_ok({binary => $chunk2})->send_ok({binary => $chunk3})->message_ok;

$res = decode_json($t->message->[1]);

my $success = $res->{document_upload};

is $success->{status}, 'success', 'File is successfully uploaded';
is $success->{upload_id}, $upload_id, 'upload id is correct';
is $success->{call_type}, $call_type, 'call_type is correct';
is $success->{size}, 11, 'file size is correct';
is $success->{checksum}, sha1_hex('Hello World'), 'checksum is correct';

done_testing();
