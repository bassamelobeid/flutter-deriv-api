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
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use TestHelper qw/test_schema build_mojo_test/;

sub do_testing {
    my $connections = 1000;
    my $counter     = 0;
    my @pool        = ();

    while ($counter < $connections) {
        my $t = build_mojo_test();

        $t = $t->send_ok({json => {active_symbols => 'brief'}})->message_ok;
        my $res = decode_json($t->message->[1]);
        ok $res->{active_symbols};
        is $res->{msg_type}, 'active_symbols';
        test_schema('active_symbols', $res);

        $t = $t->send_ok({json => {landing_company_details => 'iom'}})->message_ok;
        $res = decode_json($t->message->[1]);
        ok $res->{landing_company_details};
        is $res->{landing_company_details}->{country}, 'Isle of Man';
        test_schema('landing_company_details', $res);

        push @pool, $t;
        $counter++;
    }

    foreach my $conn (@pool) {
        $conn->finished_ok(1000);
    }
}

BOM::Test::ResourceEvaluator::evaluate(\&do_testing);

done_testing();

1;
