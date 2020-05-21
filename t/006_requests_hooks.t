use strict;
use warnings;

use Test::More;
use Test::MockObject;
use Log::Any::Test;
use Log::Any qw($log);

use Binary::WebSocketAPI::Hooks;

subtest 'add_req_data' => sub {
    subtest 'Skip data sanitize for invalid requests' => sub {
        my $c_mock = Test::MockObject->new();
        $c_mock->set_false('tx');

        my $test_tokens = ['some secret', 'some another secret'];

        my $storage = {args => {tokens => $test_tokens}};

        my $response = {
            msg_type => 'buy_contract_for_multiple_accounts',
            error    => {code => 'InputValidationFailed'},
        };

        Binary::WebSocketAPI::Hooks::add_req_data($c_mock, $storage, $response);

        is_deeply $response->{echo_req}{tokens}, $test_tokens, 'Sanitization was skipped';
    };

    subtest 'Perform sanitization for valid requests' => sub {
        my $c_mock = Test::MockObject->new();
        $c_mock->set_false('tx');

        my $test_tokens = ['some secret', 'some another secret'];

        my $storage = {args => {tokens => $test_tokens}};

        my $response = {msg_type => 'buy_contract_for_multiple_accounts'};

        Binary::WebSocketAPI::Hooks::add_req_data($c_mock, $storage, $response);

        is_deeply $response->{echo_req}{tokens}, [('<not shown>') x $test_tokens->@*], 'Sanitization was performed';
    };
};

subtest 'output_validation with undefined msg_type' => sub {
    my $req_storage = {
        msg_type => 'ticks_history',
        name     => 'ticks_history'
    };
    my $api_response = {};
    my $c_mock       = Test::MockObject->new({});
    $c_mock->mock(l => sub { shift; shift });
    $c_mock->mock(new_error => sub { shift; {error => join "", @_} });
    $log->clear();
    Binary::WebSocketAPI::Hooks::output_validation($c_mock, $req_storage, $api_response);

    $log->contains_ok(qr/Schema validation failed because msg_type is null/);
    like($api_response->{error}, qr/validation failed: An error occurred/, 'api_response will have an error');
};

done_testing();

