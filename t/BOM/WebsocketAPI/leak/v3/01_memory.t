use strict;
use warnings;

use JSON;
use JSON::Schema;
use File::Slurp;
use Mojo::JSON;
use Test::Mojo;
use Test::Most;
use Data::Dumper;

use BOM::Test::ResourceEvaluator;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

sub do_testing {
    my $connections = 100;
    my $svr         = $ENV{BOM_WEBSOCKETS_SVR} || '';
    my $counter     = 0;
    my @pool        = ();

    my $strip_doc_send = sub {
        my $data = shift;
        my $r;
        for my $p (keys %{$data->{properties}}) {
            $r->{$p} = $data->{properties}->{$p}->{sample} // {};
        }
        return $r;
    };

    while ($counter < $connections) {
        my $t = $svr ? Test::Mojo->new : Test::Mojo->new('BOM::WebSocketAPI');
        $t->websocket_ok("$svr/websockets/v3");
        my $send = &$strip_doc_send(JSON::from_json(File::Slurp::read_file("config/v3/active_symbols/example.json")));
        $t->send_ok({json => $send}, "send request for active_symbols");
        $t->message_ok("active_symbols got a response");

        my $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("config/v3/active_symbols/receive.json")));
        my $result    = $validator->validate(Mojo::JSON::decode_json $t->message->[1]);
        ok $result, "active_symbols response is valid";
        if (not $result) { print " - $_\n" foreach $result->errors; print Data::Dumper::Dumper(Mojo::JSON::decode_json $t->message->[1]) }

        $send = &$strip_doc_send(JSON::from_json(File::Slurp::read_file("config/v3/contracts_for/example.json")));
        $t->send_ok({json => $send}, "send request for contracts_for");
        $t->message_ok("contracts_for got a response");

        $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("config/v3/contracts_for/receive.json")));
        $result    = $validator->validate(Mojo::JSON::decode_json $t->message->[1]);
        ok $result, "contracts_for response is valid";
        if (not $result) { print " - $_\n" foreach $result->errors; print Data::Dumper::Dumper(Mojo::JSON::decode_json $t->message->[1]) }

        push @pool, $t;
        $counter++;
    }

    foreach my $conn (@pool) {
        $conn->finished_ok;
    }

    undef $strip_doc_send;
}

BOM::Test::ResourceEvaluator::evaluate(\&do_testing);

done_testing();

1;
