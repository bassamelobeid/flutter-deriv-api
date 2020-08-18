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
    $c_mock->mock(l         => sub { shift; shift });
    $c_mock->mock(new_error => sub { shift; {error => join "", @_} });
    $log->clear();
    Binary::WebSocketAPI::Hooks::output_validation($c_mock, $req_storage, $api_response);

    $log->contains_ok(qr/Schema validation failed because msg_type is null/);
    like($api_response->{error}, qr/validation failed: An error occurred/, 'api_response will have an error');
};

subtest 'get rpc url suffix' => sub {
    my $app_mock = Test::MockObject->new({});
    $app_mock->mock(config => sub { +{rpc_url_red => 1, rpc_url_test_red => 1, rpc_url => 1, rpc_url_test => 1} });

    my $c_mock = Test::MockObject->new({});
    $c_mock->mock(app_id => sub { 1 });
    $c_mock->mock(app    => sub { $app_mock });

    local %Binary::WebSocketAPI::DIVERT_MSG_GROUP = (
        test_grp  => 'test',
        test_grp1 => 'test1'
    );
    local %Binary::WebSocketAPI::DIVERT_APP_IDS = (10 => 'red');

    my $suffix = Binary::WebSocketAPI::Hooks::_rpc_suffix($c_mock, +{});
    is $suffix, '', 'No sufix';

    $suffix = Binary::WebSocketAPI::Hooks::_rpc_suffix($c_mock, +{msg_group => 'test_grp'});
    is $suffix, '_test', 'msg group suffix';

    $suffix = Binary::WebSocketAPI::Hooks::_rpc_suffix($c_mock, +{msg_group => 'test_grp1'});
    is $suffix, '', 'msg group is not in config';

    $c_mock->mock(app_id => sub { 10 });
    $suffix = Binary::WebSocketAPI::Hooks::_rpc_suffix($c_mock, +{});
    is $suffix, '_red', 'app id suffix';

    $suffix = Binary::WebSocketAPI::Hooks::_rpc_suffix($c_mock, +{msg_group => 'test_grp'});
    is $suffix, '_test_red', 'msg group and app id  suffixes';
};

done_testing();

