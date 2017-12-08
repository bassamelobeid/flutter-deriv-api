use strict;
use warnings;

use Test::More;
use Test::Mojo;
use File::Slurper qw/read_text read_dir/;
use JSON::Schema;
use JSON::MaybeXS;
use Encode;
use Data::Dumper;

my $json = JSON::MaybeXS->new;

my $SCHEMA_DIR = '/home/git/regentmarkets/binary-websocket-api/config/v3/';

subtest 'Examples match the send schema' => sub {
    for my $call_name (read_dir($SCHEMA_DIR)) {
        my $call_dir    = "$SCHEMA_DIR/$call_name";
        my $send_schema = read_text("$call_dir/send.json");
        my $validator = JSON::Schema->new($json->decode($send_schema));

        my $example = read_text("$call_dir/example.json");
        my $request = $json->decode($example);
        my $result  = $validator->validate($request);
        ok $result, "$call_name response is valid";

        if (not $result) {
            diag Dumper(\$request);
            diag " - $_" foreach $result->errors;
            last;
        }
    }
};

done_testing();
