package BOM::WebSocketAPI::Dispatcher;

use Mojo::Base 'Mojolicious::Controller';
use BOM::WebSocketAPI::Dispatcher::Config;
use BOM::WebSocketAPI::CallingEngine;
use BOM::WebSocketAPI::v3::Wrapper::System;

use Time::Out qw(timeout);

sub ok {
    my $c      = shift;
    my $source = 1;       # check http origin here
    $c->stash(source => $source);
    return 1;
}

sub set_connection {
    my ($c) = @_;

    # TODO
    my $log = $c->app->log;
    $log->debug("opening a websocket for " . $c->tx->remote_address);

    # enable permessage-deflate
    $c->tx->with_compression;

    # Increase inactivity timeout for connection a bit
    Mojo::IOLoop->singleton->stream($c->tx->connection)->timeout(120);
    Mojo::IOLoop->singleton->max_connections(100000);

    $c->redis;
    $c->redis_pricer;
    # /TODO

    $c->on(json => \&on_message);

    # stop all recurring
    $c->on(
        finish => sub {
            my $c = shift;
            BOM::WebSocketAPI::v3::Wrapper::System::forget_all($c, {forget_all => 1});
            delete $c->stash->{redis};
            delete $c->stash->{redis_pricer};
        });

    return;
}

sub on_message {
    my ($c, $args) = @_;

    my $config = BOM::WebSocketAPI::Dispatcher::Config->new->{config};

    my $result;
    timeout 15 => sub {
        my $req = {};    # TODO request storage
        $result = $c->parse_req($args);
        if (!$result
            && (my $action = $c->dispatch($args)))
        {
            %$req          = %$action;
            $req->{args}   = $args;
            $req->{method} = $req->{name};
            $result        = $c->before_forward($req);

            # Don't forward call to RPC if any before_forward hook returns response
            unless ($result) {
                $result =
                      $req->{instead_of_forward}
                    ? $req->{instead_of_forward}->($c, $req)
                    : $c->forward($req);
            }

            $result = $c->after_forward($args, $result, $req);
        } elsif (!$result) {
            $c->app->log->debug("unrecognised request: " . $c->dumper($args));
            $result = $c->new_error('error', 'UnrecognisedRequest', $c->l('Unrecognised request.'));
        }
    };
    if ($@) {
        $c->app->log->info("$$ timeout for " . JSON::to_json($args));
    }

    $c->send({json => $result}) if $result;

    $c->_run_hooks($config->{after_dispatch} || []);

    return;
}

sub before_forward {
    my ($c, $req) = @_;

    my $config = BOM::WebSocketAPI::Dispatcher::Config->new->{config};

    # Should first call global hooks
    my $before_forward_hooks = [
        ref($config->{before_forward}) eq 'ARRAY' ? @{$config->{before_forward}}     : $config->{before_forward},
        ref($req->{before_forward}) eq 'ARRAY'    ? @{delete $req->{before_forward}} : delete $req->{before_forward},
    ];

    return $c->_run_hooks($before_forward_hooks, $req);
}

sub after_forward {
    my ($c, $args, $result, $req) = @_;

    my $config = BOM::WebSocketAPI::Dispatcher::Config->new->{config};
    return $c->_run_hooks($config->{after_forward} || [], $args, $result, $req);
}

sub _run_hooks {
    my @hook_params = @_;
    my $c           = shift @hook_params;
    my $hooks       = shift @hook_params;

    my $i = 0;
    my $result;
    while (!$result && $i < @$hooks) {
        my $hook = $hooks->[$i++];
        next unless $hook;
        $result = $hook->($c, @hook_params);
    }

    return $result;
}

sub dispatch {
    my ($c, $args) = @_;

    my $log = $c->app->log;
    $log->debug("websocket got json " . $c->dumper($args));

    my ($action) =
        sort { $a->{order} <=> $b->{order} }
        grep { defined }
        map  { BOM::WebSocketAPI::Dispatcher::Config->new->{actions}->{$_} } keys %$args;

    return $action;
}

sub forward {
    my ($c, $req) = @_;

    my $config = BOM::WebSocketAPI::Dispatcher::Config->new->{config};

    my $url = $ENV{RPC_URL} || 'http://127.0.0.1:5005/';
    if (BOM::System::Config::env eq 'production') {
        if (BOM::System::Config::node->{node}->{www2}) {
            $url = 'http://internal-rpc-www2-703689754.us-east-1.elb.amazonaws.com:5005/';
        } else {
            $url = 'http://internal-rpc-1484966228.us-east-1.elb.amazonaws.com:5005/';
        }
    }
    $req->{url} = $url;

    for my $hook (qw/ before_call before_get_rpc_response after_got_rpc_response before_send_api_response after_sent_api_response /) {
        $req->{$hook} = [
            grep { $_ } (ref $config->{$hook} eq 'ARRAY' ? @{$config->{$hook}} : $config->{$hook}),
            grep { $_ } (ref $req->{$hook} eq 'ARRAY'    ? @{$req->{$hook}}    : $req->{$hook}),
        ];
    }

    BOM::WebSocketAPI::CallingEngine::call_rpc($c, $req);
    return;
}

sub parse_req {
    my ($c, $args) = @_;

    my $result;
    if (ref $args ne 'HASH') {
        # for invalid call, eg: not json
        $result = $c->new_error('error', 'BadRequest', $c->l('The application sent an invalid request.'));
        $result->{echo_req} = {};
    }

    $result = $c->_check_sanity($args) unless $result;

    return $result;
}

sub _check_sanity {
    my ($c, $args) = @_;

    my @failed;

    OUTER:
    foreach my $k (keys %$args) {
        if (not ref $args->{$k}) {
            last OUTER if (@failed = _failed_key_value($k, $args->{$k}));
        } else {
            if (ref $args->{$k} eq 'HASH') {
                foreach my $l (keys %{$args->{$k}}) {
                    last OUTER
                        if (@failed = _failed_key_value($l, $args->{$k}->{$l}));
                }
            } elsif (ref $args->{$k} eq 'ARRAY') {
                foreach my $l (@{$args->{$k}}) {
                    last OUTER if (@failed = _failed_key_value($k, $l));
                }
            }
        }
    }

    if (@failed) {
        $c->app->log->warn("Sanity check failed: " . $failed[0] . " -> " . ($failed[1] // "undefined"));
        my $result = $c->new_error('sanity_check', 'SanityCheckFailed', $c->l("Parameters sanity check failed."));
        if (    $result->{error}
            and $result->{error}->{code} eq 'SanityCheckFailed')
        {
            $result->{echo_req} = {};
        } else {
            $result->{echo_req} = $args;
        }
        return $result;
    }
    return;
}

sub _failed_key_value {
    my ($key, $value) = @_;

    state $pwd_field = {map { $_ => 1 } qw( client_password old_password new_password unlock_password lock_password )};

    if ($pwd_field->{$key}) {
        return;
    } elsif (
        $key !~ /^[A-Za-z0-9_-]{1,50}$/
        # !-~ to allow a range of acceptable characters. To find what is the range, look at ascii table

        # please don't remove: \p{Script=Common}\p{L}
        # \p{L} is to match utf-8 characters
        # \p{Script=Common} is to match double byte characters in Japanese keyboards, eg: '１−１−１'
        # refer: http://perldoc.perl.org/perlunicode.html
        # null-values are allowed
        or ($value and $value !~ /^[\p{Script=Common}\p{L}\s\w\@_:!-~]{0,300}$/))
    {
        return ($key, $value);
    }
    return;
}

1;
