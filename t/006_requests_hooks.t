use strict;
use warnings;

use Test::More;
use Test::MockObject;

use Binary::WebSocketAPI::Hooks;


subtest 'add_req_data' => sub {
    subtest 'Skip data sanitize for invalid requests' => sub {
        my $c_mock = Test::MockObject->new();
        $c_mock->set_false('tx');

        my $test_tokens = ['some secret', 'some another secret'];

        my $storage = { args => { tokens => $test_tokens } };

        my $response = {
            msg_type => 'buy_contract_for_multiple_accounts',
            error    => { code => 'InputValidationFailed' },
        };

        Binary::WebSocketAPI::Hooks::add_req_data($c_mock, $storage, $response);

        is_deeply $response->{echo_req}{tokens}, $test_tokens, 'Sanitization was skipped'
    };

    subtest 'Perform sanitization for valid requests' => sub {
        my $c_mock = Test::MockObject->new();
        $c_mock->set_false('tx');

        my $test_tokens = ['some secret', 'some another secret'];

        my $storage = { args => { tokens => $test_tokens } };

        my $response = { msg_type => 'buy_contract_for_multiple_accounts' };

        Binary::WebSocketAPI::Hooks::add_req_data($c_mock, $storage, $response);

        is_deeply $response->{echo_req}{tokens}, [('<not shown>') x $test_tokens->@*], 'Sanitization was performed'
    };
};

done_testing();

