use Test::Most;
use Test::MockObject;
use Test::MockModule;
use JSON::MaybeUTF8 qw(:v1);

use Binary::WebSocketAPI::Plugins::CircuitBreaker;
use Binary::WebSocketAPI::Plugins::Longcode;

sub mock_c {
    my $c = Test::MockObject->new;
    $c->{stash} = {};
    $c->mock('stash',     sub { shift; my $key = shift; return $c->{stash}->{$key} if 1 > @_; $c->{stash}->{$key} = shift; });
    $c->mock('l',         sub { shift; shift; });
    $c->mock('call_rpc',  sub { shift; return shift; });
    $c->mock('new_error', sub { shift; shift; return {code => shift, message => shift} });
    return $c;
}

sub mock_app {
    my $mocked_app = Test::MockObject->new;
    $mocked_app->{helpers} = {};
    $mocked_app->mock('helper', sub { $mocked_app->{helpers}->{$_[1]} = $_[2]; });

    return $mocked_app;
}

sub mock_site_status_monitor {
    my $site_state                 = shift;
    my $mocked_site_status_monitor = Test::MockModule->new('Binary::WebSocketAPI::SiteStatusMonitor');
    $mocked_site_status_monitor->mock('site_status', sub { return $site_state->{status} });
    return $mocked_site_status_monitor;
}

subtest 'Longcode' => sub {
    my $c = mock_c();
    $c->stash('language' => 'en');

    my $plugin = new_ok('Binary::WebSocketAPI::Plugins::Longcode' => []);

    is $plugin->memory_cache_key('USD', 'en', 'cr'), "USD\0en\0cr", 'memory_cache_key matches';

    is $plugin->pending_request_key('USD', 'en'), "USD\0en", 'pending_request_key matches';

    isa_ok $plugin->longcode($c, 'cr', 'USD'), 'Future::Mojo', 'longcode';
};

subtest 'CircularBreaker' => sub {
    my $c          = mock_c();
    my $mocked_app = mock_app();
    my $plugin;

    subtest 'register' => sub {
        $plugin = new_ok('Binary::WebSocketAPI::Plugins::CircuitBreaker');
        is $mocked_app->{helpers}->{circuit_breaker}, undef, 'circuit_breaker helper not registered';
        $plugin->register($mocked_app);
        isa_ok $mocked_app->{helpers}->{circuit_breaker}, 'CODE', 'circuit_breaker helper registered';
    };

    subtest 'circuit_state_controller - site is up' => sub {
        my $site_state                 = {status => 'up'};
        my $mocked_site_status_monitor = mock_site_status_monitor($site_state);
        my $circuit_state              = $plugin->_circuit_state_controller();
        is_deeply $circuit_state,
            {
            closed => 1,
            open   => ''
            },
            'circuit_state_controller';
    };

    subtest 'circuit_state_controller - site is down' => sub {
        my $site_state                 = {status => 'down'};
        my $mocked_site_status_monitor = mock_site_status_monitor($site_state);
        my $circuit_state              = $plugin->_circuit_state_controller();
        is_deeply $circuit_state,
            {
            closed => '',
            open   => 1
            },
            'circuit_state_controller';
    };

    subtest 'circuit_breaker - circuit is closed' => sub {
        my $site_state                 = {status => 'up'};
        my $mocked_site_status_monitor = mock_site_status_monitor($site_state);
        my $circuit_state              = $plugin->_circuit_state_controller();
        is $circuit_state->{closed}, 1, 'circuit_state_controller - circuit is closed';
        my $future = $mocked_app->{helpers}->{circuit_breaker}->($c, 'website_status');
        isa_ok $future, 'Future', 'Returned future';
        is $future->is_ready, 1, 'circuit_breaker - circuit is closed';
    };

    subtest 'circuit_breaker - circuit is open' => sub {
        my $site_state                 = {status => 'down'};
        my $mocked_site_status_monitor = mock_site_status_monitor($site_state);
        my $circuit_state              = $plugin->_circuit_state_controller();
        is $circuit_state->{open}, 1, 'circuit_state_controller - circuit is open';

        subtest 'open circuit - Excluded calls' => sub {
            my $future = $mocked_app->{helpers}->{circuit_breaker}->($c, 'website_status');
            is $future->is_ready, 1, 'circuit_breaker - circuit is open';
            isa_ok $future, 'Future', 'Returned future';

            $future = $mocked_app->{helpers}->{circuit_breaker}->($c, 'ping');
            isa_ok $future, 'Future', 'Returned future';
            is $future->is_ready, 1, 'circuit_breaker - circuit is open';
        };

        subtest 'open circuit - Non excluded calls ' => sub {
            my $future = $mocked_app->{helpers}->{circuit_breaker}->($c, 'time');
            isa_ok $future, 'Future', 'Returned future';
            is $future->failure->{code}, 'ServiceUnavailable', 'correct error code';
            is $future->failure->{message},
                'The server is currently unable to handle the request due to a temporary overload or maintenance of the server. Please try again later.',
                'correct error message';
        };
    };

};

done_testing();
