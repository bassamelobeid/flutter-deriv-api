use Test::Most;
use Test::Mojo;
use JSON::Schema;
use JSON;
use File::Slurp;
use File::Basename;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();
use Finance::Asset;
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use Date::Utility;
use BOM::Test::Data::Utility::FeedTestDatabase;
my @exchange = map { BOM::Market::Underlying->new($_)->exchange_name } Finance::Asset->instance->symbols;
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(    # .. why isn't this in the testdb by default anyway?
    'exchange',
    {
        symbol           => $_,
        date             => Date::Utility->new,
        trading_days     => 'everyday',
        open_on_weekends => 1
    }) for @exchange;
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_100',
    epoch      => Date::Utility->new->epoch,
    quote      => 100
});

my $svr = $ENV{BOM_WEBSOCKETS_SVR} || '';
my $t = $svr ? Test::Mojo->new : Test::Mojo->new('BOM::WebSocketAPI');

$t->websocket_ok("$svr/websockets/v2");

my ($test_name, $response);

my $v = 'config/v2';
explain "Testing version: $v";
foreach my $f (grep { -d } glob "$v/*") {
    $test_name = File::Basename::basename($f);
    explain $f;
    my $send = strip_doc_send(JSON::from_json(File::Slurp::read_file("$f/send.json")));
    $t->send_ok({json => $send}, "send request for $test_name");
    $t->message_ok("$test_name got a response");
    my $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/receive.json")));
    my $result    = $validator->validate(Mojo::JSON::decode_json $t->message->[1]);
    ok $result, "$f response is valid";
    if (not $result) { print " - $_\n" foreach $result->errors; print Data::Dumper::Dumper(Mojo::JSON::decode_json $t->message->[1]) }
}

sub strip_doc_send {
    my $data = shift;
    my $r;
    for my $p (keys %{$data->{properties}}) {
        $r->{$p} = $data->{properties}->{$p}->{sample} // {};
    }
    return $r;
}

done_testing();
