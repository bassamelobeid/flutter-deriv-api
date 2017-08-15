use strict;
use warnings;

use Test::Most;
use Test::MockTime qw/:all/;
use JSON;
use Data::Dumper;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test build_test_R_50_data/;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::AccessToken;

my $t = build_wsapi_test({rpc_url => 'ws://localhost:5004'});

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

done_testing();
