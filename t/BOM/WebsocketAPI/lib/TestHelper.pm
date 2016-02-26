package TestHelper;

use strict;
use warnings;
use Test::More;
use Test::Mojo;

use JSON::Schema;
use File::Slurp;
use Data::Dumper;

use Date::Utility;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMD qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use base 'Exporter';
use vars qw/@EXPORT_OK/;
@EXPORT_OK = qw/test_schema build_mojo_test build_test_R_50_data/;

my ($version) = (__FILE__ =~ m{/(v\d+)/});
die 'unknown version' unless $version;

sub build_mojo_test {
    my $args = shift || {};

    my $headers = {};
    if ($args->{deflate}) {
        $headers = {'Sec-WebSocket-Extensions' => 'permessage-deflate'};
    }
    my $url = "/websockets/$version";
    $url .= '?l=' . $args->{language} if $args->{language};
    my $t = Test::Mojo->new('BOM::WebSocketAPI');
    $t->websocket_ok($url => $headers);

    return $t;
}

sub test_schema {
    my ($type, $data) = @_;

    my $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("config/$version/$type/receive.json")));
    my $result    = $validator->validate($data);
    ok $result, "$type response is valid";
    if (not $result) {
        diag Dumper(\$data);
        diag " - $_" foreach $result->errors;
    }
}

sub build_test_R_50_data {
    initialize_realtime_ticks_db();

    BOM::Test::Data::Utility::UnitTestMD::create_doc('currency', {symbol => $_}) for qw(USD);
    BOM::Test::Data::Utility::UnitTestMD::create_doc(
        'randomindex',
        {
            symbol => 'R_50',
            date   => Date::Utility->new
        });
}

1;
