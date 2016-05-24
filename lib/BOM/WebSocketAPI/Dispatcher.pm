package BOM::WebSocketAPI::Dispatcher;

use Mojo::Base 'Mojolicious::Controller';
use BOM::WebSocketAPI::CallingEngine;
use BOM::WebSocketAPI::v3::Wrapper::System;

use Data::UUID;

my $routes;
my $config;

sub ok {
    my $c      = shift;
    my $source = 1;       # check http origin here
    $c->stash(source => $source);
    return 1;
}

sub init {
    my ($c, $in_config) = @_;

    %$config = %$in_config;
}

sub add_route {
    my ($c, $action, $order) = @_;
    my $name    = $action->[0];
    my $options = $action->[1];

    $routes->{$name} ||= $options;
    $routes->{$name}->{order} = $order;
    $routes->{$name}->{name}  = $name;

    my $f             = '/home/git/regentmarkets/bom-websocket-api/config/v3/' . $name;
    my $in_validator  = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/send.json")), format => \%JSON::Schema::FORMATS);
    my $out_validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/receive.json")), format => \%JSON::Schema::FORMATS);

    $routes->{$name}->{in_validator}  = $in_validator;
    $routes->{$name}->{out_validator} = $out_validator;
}

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

    $c->redis;
    $c->redis_pricer;
    # /TODO

    $c->on(json => \&forward);

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

    my $result;
    timeout 15 => sub {
        my $req = {};    # TODO request storage
        $result = $c->parse_req($p1);
        if (!$result
            && my $route = $c->dispatch($p1))
        {
            %$req = %$route;

            for my $hook (qw/ before_call before_get_rpc_response after_got_rpc_response before_send_api_response after_sent_api_response /) {
                $req->{$hook} = [
                    grep { $_ } (ref $config->{$hook} eq 'ARRAY' ? @{$config->{$hook}} : $config->{$hook}),
                    grep { $_ } (ref $config->{$hook} eq 'ARRAY' ? @{route->{$hook}}   : route->{$hook}),
                ];
            }

            $result = $c->before_forward($p1, $req)
                || $c->forward($p1, $req);    # Don't forward call to RPC if before_forward hook returns anything
        } elsif (!$result) {
            $log->debug("unrecognised request: " . $c->dumper($p1));
            $result = $c->new_error('error', 'UnrecognisedRequest', $c->l('Unrecognised request.'));
        }

        # TODO move out
        if ($result) {
            my $output_validation_result = $descriptor->{out_validator}->validate($result);
            if (not $output_validation_result) {
                my $error = join(" - ", $output_validation_result->errors);
                $log->warn("Invalid output parameter for [ " . JSON::to_json($result) . " error: $error ]");
                $result = $c->new_error($descriptor->{category}, 'OutputValidationFailed', $c->l("Output validation failed: ") . $error);
            }
        }
        if (ref($result) && $c->stash('debug')) {
            $result->{debug} = {
                time   => 1000 * Time::HiRes::tv_interval($req->{hadle_t0}),
                method => $descriptor->{category},
            };
        }
        my $l = length JSON::to_json($result || {});
        if ($l > 328000) {
            $result = $c->new_error('error', 'ResponseTooLarge', $c->l('Response too large.'));
            $result->{echo_req} = $p1;
        }

        $result->{req_id} = $p1->{req_id} if $result && exists $p1->{req_id};
    };
    if ($@) {
        $c->app->log->info("$$ timeout for " . JSON::to_json($p1));
    }

    $c->send({json => $result}) if $result;

    BOM::Database::Rose::DB->db_cache->finish_request_cycle;    # TODO
    return;
}

sub before_forward {
    my ($c, $p1, $req) = @_;

    my $result;

    # Should first call global hooks
    my $before_forward_hooks = [
        ref($config->{before_forward}) eq 'ARRAY'       ? @{$config->{before_forward}}            : $config->{before_forward},
        ref($route->{action_before_forward}) eq 'ARRAY' ? @{delete $req->{action_before_forward}} : delete $req->{action_before_forward},
    ];

    my $i = 0;
    while (!$result && $i < @$before_forward_hooks) {
        next unless $before_forward_hooks->[$i];
        $result = $before_forward_hooks->[$i++]->($c, $p1, $req);
    }

    return $result;
}

sub dispatch {
    my ($c, $p1) = @_;

    my $log = $c->app->log;
    $log->debug("websocket got json " . $c->dumper($p1));

    my ($route) =
        sort { $a->{order} <=> $b->{order} }
        grep { defined }
        map  { $routes->{$_} } keys %$p1;

    return $route;
}

sub forward {
    my ($c, $p1, $req) = @_;

    # TODO New dispatcher plugin has to do this
    my $url = $ENV{RPC_URL} || 'http://127.0.0.1:5005/';
    if (BOM::System::Config::env eq 'production') {
        if (BOM::System::Config::node->{node}->{www2}) {
            $url = 'http://internal-rpc-www2-703689754.us-east-1.elb.amazonaws.com:5005/';
        } else {
            $url = 'http://internal-rpc-1484966228.us-east-1.elb.amazonaws.com:5005/';
        }
    }

    my $name = $req->{name};
    BOM::WebSocketAPI::CallingEngine::forward($c, $url, $name, $p1, $req);

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

    $result = $c->check_sanity($p1) unless $result;

    return $result;
}

sub check_sanity {
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

# Set JSON Schema default values for fields which are missing and have default.
sub _set_defaults {
    my ($validator, $args) = @_;

    my $properties = $validator->{in_validator}->schema->{properties};

    foreach my $k (keys %$properties) {
        $args->{$k} = $properties->{$k}->{default} if not exists $args->{$k} and $properties->{$k}->{default};
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

my %rate_limit_map = (
    ping_real                      => '',
    time_real                      => '',
    portfolio_real                 => 'websocket_call_expensive',
    statement_real                 => 'websocket_call_expensive',
    profit_table_real              => 'websocket_call_expensive',
    proposal_real                  => 'websocket_real_pricing',
    pricing_table_real             => 'websocket_real_pricing',
    proposal_open_contract_real    => 'websocket_real_pricing',
    verify_email_real              => 'websocket_call_email',
    buy_real                       => 'websocket_real_pricing',
    sell_real                      => 'websocket_real_pricing',
    reality_check_real             => 'websocket_call_expensive',
    ping_virtual                   => '',
    time_virtual                   => '',
    portfolio_virtual              => 'websocket_call_expensive',
    statement_virtual              => 'websocket_call_expensive',
    profit_table_virtual           => 'websocket_call_expensive',
    proposal_virtual               => 'websocket_call_pricing',
    pricing_table_virtual          => 'websocket_call_pricing',
    proposal_open_contract_virtual => 'websocket_call_pricing',
    verify_email_virtual           => 'websocket_call_email',
);

sub _reached_limit_check {
    my ($connection_id, $category, $is_real) = @_;

    my $limiting_service = $rate_limit_map{
        $category . '_'
            . (
            ($is_real)
            ? 'real'
            : 'virtual'
            )} // 'websocket_call';
    if (
        $limiting_service
        and not within_rate_limits({
                service  => $limiting_service,
                consumer => $connection_id,
            }))
    {
        return 1;
    }
    return;
}

1;
