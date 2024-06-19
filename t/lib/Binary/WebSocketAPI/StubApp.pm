package Binary::WebSocketAPI::StubApp;

use strict;
use warnings;
use Test::MockObject;

sub new {
    my $class  = shift;
    my $self   = {};
    my $config = {};
    bless $self, $class;

    my $app = Test::MockObject->new();

    $app->mock(
        'moniker',
        sub {
        });

    $app->mock(
        'check_connections',
        sub {
            return 1;
        });

    # Stub Mojo::IOLoop singleton reactor on method indirectly
    $app->mock(
        'reactor_on',
        sub {
            my ($self, $event_name, $cb) = @_;
            # Implementation
            Mojo::IOLoop->singleton->reactor->on($event_name => $cb);
        });

    $app->mock(
        'apply_usergroup',
        sub {
        });

    # Stub plugins->namespaces to return an array
    $app->mock(
        'plugins',
        sub {
            my $plugins = Test::MockObject->new();
            $plugins->mock(
                'namespaces',
                sub {
                    return ['MyApp::Plugin::Namespace1', 'MyApp::Plugin::Namespace2'];
                });
            return $plugins;
        });

    # Stub plugins->namespaces to return an array
    $app->mock(
        'config',
        sub {
            return $config;
        });

    $app->mock(
        'mode',
        sub {
            return "TestMock";
        });

    $app->mock(
        'plugin',
        sub {
        });

    $app->mock(
        'hook',
        sub {
        });

    $app->mock(
        'helper',
        sub {
        });

    $app->mock(
        'backend_setup',
        sub {
        });

    $app->mock(
        'routes',
        sub {
            my $routes = Test::MockObject->new();
            $routes->mock(
                'any',
                sub {
                });
            return $routes;
        });

    $self->{app} = $app;
    return $self;
}

1;
