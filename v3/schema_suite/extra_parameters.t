use strict;
use warnings;
use Test::Most;
use Dir::Self;
use JSON::MaybeXS;
use Path::Tiny;
use BOM::Test::Suite::DSL;

# This test verifies "additionalProperties":false is set for inner json objects

my $json       = JSON::MaybeXS->new;
my $SCHEMA_DIR = '/home/git/regentmarkets/binary-websocket-api/config/v3/';

subtest 'Check specfic calls' => sub {

    my $suite = start(
        title             => "extra_parameters.t",
        test_app          => 'Binary::WebSocketAPI',
        suite_schema_path => __DIR__ . '/config/',
    );

    set_language 'EN';

    # Create virtual account
    test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test@binary.com', 'account_opening';
    test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
        $suite->get_token('test@binary.com'), 'test@binary.com', 'gb';
    test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
        $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'test@binary.com';

    test_sendrecv_params 'extra_parameters/buy.json',                                'extra_parameters/error.json', '.*parameters';
    test_sendrecv_params 'extra_parameters/buy_contract_for_multiple_accounts.json', 'extra_parameters/error.json', '.*parameters',
        $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token');

    test_sendrecv_params 'extra_parameters/proposal_array.json', 'extra_parameters/error.json', '.*barriers.0';
};

subtest 'Nested objects in all calls' => sub {
    for my $call_name (path($SCHEMA_DIR)->children) {
        next if $call_name =~ /draft-03/;
        my $contents = path("$call_name/send.json")->slurp_utf8;
        my $props    = $json->decode($contents)->{properties};
        delete $props->{passthrough};
        my @els = check($props);
        ok(!@els, path($call_name)->basename . " nested objects prohibit additionalProperties")
            or diag("Attribute(s): @els");
    }
};

sub check {
    my ($cur, $e) = @_;
    return unless ref $cur eq "HASH";
    my @els;

    # objects must have an element "additionalProperties" and it must be False
    if ($cur->{type} and $cur->{type} eq "object" and not(defined $cur->{additionalProperties} and not $cur->{additionalProperties})) {
        push @els, $e;
    }

    if ($cur->{type} and $cur->{type} eq 'array') {
        push @els, check($cur->{items}, $e);
    } else {
        push @els, check($cur->{$_}, $_) for sort keys %$cur;
    }

    return @els;
}

finish;
