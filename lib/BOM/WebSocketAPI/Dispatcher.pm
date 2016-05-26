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
    my ($c, $p1) = @_;

    my $config = BOM::WebSocketAPI::Dispatcher::Config->new->{config};

    my $result;
    timeout 15 => sub {
        my $req = {};    # TODO request storage
        $result = $c->parse_req($p1);
        if (!$result
            && (my $action = $c->dispatch($p1)))
        {
            %$req          = %$action;
            $req->{method} = $req->{name};
            $result        = $c->before_forward($p1, $req)
                || $c->forward($p1, $req);    # Don't forward call to RPC if before_forward hook returns response

            # Do not answer if rpc called manually
            undef $result if $result && $result eq 'not_forward';

            $result = $c->after_forward($p1, $result, $req);
        } elsif (!$result) {
            $c->app->log->debug("unrecognised request: " . $c->dumper($p1));
            $result = $c->new_error('error', 'UnrecognisedRequest', $c->l('Unrecognised request.'));
        }
    };
    if ($@) {
        $c->app->log->info("$$ timeout for " . JSON::to_json($p1));
    }

    $c->send({json => $result}) if $result;

    $c->_run_hooks($config->{after_dispatch} || []);

    return;
}

sub before_forward {
    my ($c, $p1, $req) = @_;

    my $config = BOM::WebSocketAPI::Dispatcher::Config->new->{config};

    # Should first call global hooks
    my $before_forward_hooks = [
        ref($config->{before_forward}) eq 'ARRAY' ? @{$config->{before_forward}}     : $config->{before_forward},
        ref($req->{before_forward}) eq 'ARRAY'    ? @{delete $req->{before_forward}} : delete $req->{before_forward},
    ];

    return $c->_run_hooks($before_forward_hooks, $p1, $req);
}

sub after_forward {
    my ($c, $p1, $result, $req) = @_;

    my $config = BOM::WebSocketAPI::Dispatcher::Config->new->{config};
    return $c->_run_hooks($config->{after_forward} || [], $p1, $result, $req);
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
    my ($c, $p1) = @_;

    my $log = $c->app->log;
    $log->debug("websocket got json " . $c->dumper($p1));

    my ($action) =
        sort { $a->{order} <=> $b->{order} }
        grep { defined }
        map  { BOM::WebSocketAPI::Dispatcher::Config->new->{actions}->{$_} } keys %$p1;

    return $action;
}

sub forward {
    my ($c, $p1, $req) = @_;

    my $config = BOM::WebSocketAPI::Dispatcher::Config->new->{config};

    my $url = $ENV{RPC_URL} || 'http://127.0.0.1:5005/';
    if (BOM::System::Config::env eq 'production') {
        if (BOM::System::Config::node->{node}->{www2}) {
            $url = 'http://internal-rpc-www2-703689754.us-east-1.elb.amazonaws.com:5005/';
        } else {
            $url = 'http://internal-rpc-1484966228.us-east-1.elb.amazonaws.com:5005/';
        }
    }

    $req->{url}  = $url;
    $req->{args} = $p1;

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
    my ($c, $p1) = @_;

    my $result;
    if (ref $p1 ne 'HASH') {
        # for invalid call, eg: not json
        $result = $c->new_error('error', 'BadRequest', $c->l('The application sent an invalid request.'));
        $result->{echo_req} = {};
    }

    $result = $c->_check_sanity($p1) unless $result;

    return $result;
}

sub _check_sanity {
    my ($c, $p1) = @_;

    my @failed;

    OUTER:
    foreach my $k (keys %$p1) {
        if (not ref $p1->{$k}) {
            last OUTER if (@failed = _failed_key_value($k, $p1->{$k}));
        } else {
            if (ref $p1->{$k} eq 'HASH') {
                foreach my $l (keys %{$p1->{$k}}) {
                    last OUTER
                        if (@failed = _failed_key_value($l, $p1->{$k}->{$l}));
                }
            } elsif (ref $p1->{$k} eq 'ARRAY') {
                foreach my $l (@{$p1->{$k}}) {
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
            $result->{echo_req} = $p1;
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
