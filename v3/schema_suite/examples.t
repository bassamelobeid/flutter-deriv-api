use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Path::Tiny;
use JSON::Schema;
use JSON::MaybeXS;
use Encode;
use Data::Dumper;

my $json = JSON::MaybeXS->new;

my $SCHEMA_DIR = '/home/git/regentmarkets/binary-websocket-api/config/v3/';

subtest 'Examples match the send schema' => sub {
    for my $call_name (path($SCHEMA_DIR)->children) {
        my $send_schema = path("$call_name/send.json")->slurp_utf8;
        my $validator   = JSON::Schema->new($json->decode($send_schema));

        my $example = path("$call_name/example.json")->slurp_utf8;
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
