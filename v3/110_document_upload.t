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

my $t = build_wsapi_test();

my $req = {
        document_upload => 1,
        req_id => 10,
        document_type => "passport",
        expiry_date => "1345678",
        document_id => "1234567"
};

$t->send_ok({json => $req})->message_ok;

my $res = decode_json($t->message->[1]);

my $upload_id = $res->{document_upload}->{upload_id};
my $call_type = $res->{document_upload}->{call_type};

ok $upload_id, 'Should return upload_id';
ok $call_type, 'Should return call_type';

done_testing();
