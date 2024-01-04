use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Path::Tiny;
use JSON::Validator;
use JSON::MaybeXS;
use Encode;
use Data::Dumper;
use Moo::Role;
use BOM::Test::Suite;
use List::Util qw(any);

my $json = JSON::MaybeXS->new;

my $SCHEMA_DIR = '/home/git/regentmarkets/binary-websocket-api/config/v3/';

subtest 'Examples match the send schema' => sub {
    for my $call_name (path($SCHEMA_DIR)->children) {
        my $send_schema = path("$call_name/send.json")->slurp_utf8;
        my $validator   = JSON::Validator->new()->schema($json->decode($send_schema));
        $validator->schema->coerce('booleans,numbers,strings');

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

subtest 'Examples not requiring auth work without error' => sub {
    my $suite = BOM::Test::Suite->new(
        test_app          => 'Binary::WebSocketAPI',
        suite_schema_path => '/home/git/regentmarkets/binary-websocket-api/config/',
    );
    $suite->set_language('EN');
    my $test_app = $suite->test_app;

    # The following API calls require additional configuration (other prior calls) and are not callable on their own
    my @contains_fake_example = qw(
        affiliate_.*
        authorize
        copytrading_statistics
        new_account_virtual
        reset_password
        unsubscribe_email
        verify_email_cellxpert
    );

    my @requires_other_services = ('crypto_config', 'ticks', 'crypto_estimations');

    for my $call_name (sort { $a cmp $b } path($SCHEMA_DIR)->children) {
        next if any { $call_name =~ /\/$_$/ } (@contains_fake_example, @requires_other_services);
        my $send_schema = $json->decode(path("$call_name/send.json")->slurp_utf8);
        next if $send_schema->{auth_required};
        my $example  = $json->decode(path("$call_name/example.json")->slurp_utf8);
        my $response = $test_app->send_recv($example);
        if (!$response) {
            # It is already failed in send_recv.
            # Test app became unstable -- we reset it to continue testing, otherwise it hangs.
            $suite->reset_app;
            $test_app = $suite->test_app;
            next;
        }
        ok !$response->{error}, "$call_name example response has no error";
        if ($response->{error}) {
            print STDERR Dumper($response->{error});
        }
    }
};

done_testing();
