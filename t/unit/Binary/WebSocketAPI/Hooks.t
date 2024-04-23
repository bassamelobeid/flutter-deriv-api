use strict;
use warnings;

use Test::More;
use Test::MockObject;
use Test::Exception;
use Log::Any::Test;
use Log::Any qw($log);

# Need to mock rand function to test rpc_throttling and has to be done before loading the module
my $rand_response = 100;

BEGIN {
    *CORE::GLOBAL::rand = sub { return $rand_response; };
}

use Binary::WebSocketAPI::Hooks;

subtest 'rpc_throttling' => sub {

    # Test 100% throttle
    $Binary::WebSocketAPI::RPC_THROTTLE->{throttle} = 100;
    $rand_response = 0;
    dies_ok { Binary::WebSocketAPI::Hooks::rpc_throttling() } '100% throttle, should die, rand 0';
    $rand_response = 49.999;
    dies_ok { Binary::WebSocketAPI::Hooks::rpc_throttling() } '100% throttle, should die, rand 49.999';
    $rand_response = 99.999;
    dies_ok { Binary::WebSocketAPI::Hooks::rpc_throttling() } '100% throttle, should die, rand 100';

    # Test with 0% throttle
    $Binary::WebSocketAPI::RPC_THROTTLE->{throttle} = 0;
    $rand_response = 0;
    lives_ok { Binary::WebSocketAPI::Hooks::rpc_throttling() } '0% throttle, should live, rand 0';
    $rand_response = 49.999;
    lives_ok { Binary::WebSocketAPI::Hooks::rpc_throttling() } '0% throttle, should live, rand 49.999';
    $rand_response = 99.999;
    lives_ok { Binary::WebSocketAPI::Hooks::rpc_throttling() } '0% throttle, should live, rand 100';

    # Test with 50% throttle
    $Binary::WebSocketAPI::RPC_THROTTLE->{throttle} = 50;
    $rand_response = 0;
    dies_ok { Binary::WebSocketAPI::Hooks::rpc_throttling() } '50% throttle, should die, rand 0';
    $rand_response = 49.999;
    dies_ok { Binary::WebSocketAPI::Hooks::rpc_throttling() } '50% throttle, should die, rand 49.999';
    $rand_response = 50;
    lives_ok { Binary::WebSocketAPI::Hooks::rpc_throttling() } '50% throttle, should live, rand 50';
    $rand_response = 99.999;
    lives_ok { Binary::WebSocketAPI::Hooks::rpc_throttling() } '50% throttle, should live, rand 99.999';
};

END {
    undef *CORE::GLOBAL::rand;
}

subtest 'rpc_timeout_extension' => sub {
    my $c           = undef;
    my $req_storage = {};

    $req_storage = {
        category => 'any_category',
        name     => 'any_rpc'
    };
    $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION = [];
    Binary::WebSocketAPI::Hooks::rpc_timeout_extension($c, $req_storage);
    is(scalar(keys %$req_storage), 2, 'No timeout extension values added on no RPC_TIMEOUT_EXTENSION data set');

    $req_storage = {
        category => 'any_category',
        name     => 'any_rpc'
    };
    $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION = [{
            category   => '',
            rpc        => '',
            offset     => 12,
            percentage => 34
        }];
    Binary::WebSocketAPI::Hooks::rpc_timeout_extension($c, $req_storage);
    is(scalar(keys %$req_storage), 4, 'Match means 2 new keys added to req_storage, 4 total');
    is(
        $req_storage->{rpc_timeout_extend_offset},
        $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION->[0]->{offset},
        'Any wildcard category and rpc should be matched, offset returned'
    );
    is(
        $req_storage->{rpc_timeout_extend_percentage},
        $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION->[0]->{percentage},
        'Any wildcard category and rpc should be matched, percentage returned'
    );

    $req_storage = {
        category => 'any_category',
        name     => 'any_rpc'
    };
    $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION = [{
            category   => 'not_any_category',
            rpc        => 'not_any_rpc',
            offset     => 12,
            percentage => 34
        }];
    Binary::WebSocketAPI::Hooks::rpc_timeout_extension($c, $req_storage);
    is(scalar(keys %$req_storage), 2, 'No timeout extension values added on no match to RPC_TIMEOUT_EXTENSION data set');

    $req_storage = {
        category => 'any_category',
        name     => 'any_rpc'
    };
    $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION = [{
            category   => '^start',
            rpc        => '^end',
            offset     => 12,
            percentage => 34
        },
        {
            category   => '',
            rpc        => '',
            offset     => 56,
            percentage => 78
        }];
    Binary::WebSocketAPI::Hooks::rpc_timeout_extension($c, $req_storage);
    is(scalar(keys %$req_storage), 4, 'Match means 2 new keys added to req_storage, 4 total');
    is(
        $req_storage->{rpc_timeout_extend_offset},
        $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION->[1]->{offset},
        'Match to 2nd timeout entry, correct offset returned'
    );
    is(
        $req_storage->{rpc_timeout_extend_percentage},
        $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION->[1]->{percentage},
        'Match to 2nd timeout entry, correct percentage returned'
    );

    $req_storage = {
        category => 'start_category',
        name     => 'any_rpc'
    };
    $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION = [{
            category   => '^start',
            rpc        => 'end$',
            offset     => 12,
            percentage => 34
        },
        {
            category   => '',
            rpc        => '',
            offset     => 56,
            percentage => 78
        }];
    Binary::WebSocketAPI::Hooks::rpc_timeout_extension($c, $req_storage);
    is(scalar(keys %$req_storage), 4, 'Match means 2 new keys added to req_storage, 4 total');
    is(
        $req_storage->{rpc_timeout_extend_offset},
        $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION->[1]->{offset},
        'Match to 2nd timeout entry as only cat match, correct offset returned'
    );
    is(
        $req_storage->{rpc_timeout_extend_percentage},
        $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION->[1]->{percentage},
        'Match to 2nd timeout entry as only cat, correct percentage returned'
    );

    $req_storage = {
        category => 'start_category',
        name     => 'any_rpc_end'
    };
    $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION = [{
            category   => '^start',
            rpc        => 'end$',
            offset     => 12,
            percentage => 34
        },
        {
            category   => '',
            rpc        => '',
            offset     => 56,
            percentage => 78
        }];
    Binary::WebSocketAPI::Hooks::rpc_timeout_extension($c, $req_storage);
    is(scalar(keys %$req_storage), 4, 'Match means 2 new keys added to req_storage, 4 total');
    is(
        $req_storage->{rpc_timeout_extend_offset},
        $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION->[0]->{offset},
        'Match to 1st timeout entry as rpc/cat match, correct offset returned'
    );
    is(
        $req_storage->{rpc_timeout_extend_percentage},
        $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION->[0]->{percentage},
        'Match to 1st timeout entry rpc/cat, correct percentage returned'
    );
};

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
    like($api_response->{error}, qr/An unexpected error occurred:/, 'api_response will have an error');
};

done_testing();

