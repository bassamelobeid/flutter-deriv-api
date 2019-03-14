use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Path::Tiny;
use JSON::Validator;
use JSON::MaybeXS;
use Encode;
use Data::Dumper;

my $json = JSON::MaybeXS->new;

my $SCHEMA_DIR = '/home/git/regentmarkets/binary-websocket-api/config/v3/';

subtest 'Examples match the send schema' => sub {
    for my $call_name (path($SCHEMA_DIR)->children) {
        next if $call_name =~ /draft-03/;
        my $send_schema = path("$call_name/send.json")->slurp_utf8;
        my $validator   = JSON::Validator->new()->schema($json->decode($send_schema));

        $validator->coerce(
            booleans => 1,
            numbers  => 1,
            strings  => 1
        );
        my $example = path("$call_name/example.json")->slurp_utf8;
        my $request = $json->decode($example);
        my @error   = $validator->validate($request);
        ok !@error, "$call_name response is valid";

        if (@error) {
            diag Dumper(\$request);
            diag " - $_" foreach @error;
            last;
        }
    }
};

done_testing();
