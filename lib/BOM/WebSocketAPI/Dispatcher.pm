package BOM::WebSocketAPI::Dispatcher;

use Mojo::Base 'Mojolicious::Controller';
use BOM::WebSocketAPI::CallingEngine;

my $routes;

sub connect {
    my ($c) = @_;

    # TODO
    my $log = $c->app->log;
    $log->debug("opening a websocket for " . $c->tx->remote_address);

    # enable permessage-deflate
    $c->tx->with_compression;

    # Increase inactivity timeout for connection a bit
    Mojo::IOLoop->singleton->stream($c->tx->connection)->timeout(120);
    Mojo::IOLoop->singleton->max_connections(100000);
    # /TODO

    $c->on(json => \&forward);

    return;
}

sub forward {
    my ($c, $p1) = @_;

    my ($route) =
        # sort { $a->{order} <=> $b->{order} } # TODO
        grep { defined }
        map  { $routes->{$_} } keys %$p1;

    my $name = $route->{name};
    BOM::WebSocketAPI::CallingEngine::forward($c, $name, $p1, $route);

    return;
}

sub ok {
    my $c      = shift;
    my $source = 1;       # check http origin here
    $c->stash(source => $source);
    return 1;
}

sub add_route {
    my ($c, $name, $options) = @_;
    $routes->{$name} ||= $options;
    $routes->{$name}->{name} ||= $name;
}

1;
