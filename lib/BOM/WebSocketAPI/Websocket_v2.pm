package BOM::WebSocketAPI::Websocket_v2;

use Mojo::Base 'BOM::WebSocketAPI::v2::BaseController';

use BOM::WebSocketAPI::v2::Symbols;
use BOM::WebSocketAPI::v2::Authorize;
use BOM::WebSocketAPI::v2::ContractDiscovery;
use BOM::WebSocketAPI::v2::System;
use BOM::WebSocketAPI::v2::Accounts;
use BOM::WebSocketAPI::v2::MarketDiscovery;
use BOM::WebSocketAPI::v2::PortfolioManagement;
use DataDog::DogStatsd::Helper;
use JSON::Schema;
use File::Slurp;
use JSON;
use BOM::Platform::Context;
use BOM::Platform::Context::Request;
use Time::HiRes;

sub ok {
    my $c      = shift;
    my $source = 1;       # check http origin here
    $c->stash(source => $source);
    return 1;
}

sub entry_point {
    my $c = shift;

    my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => $c->req});
    if ($request) {
        BOM::Platform::Context::request($request);
    }

    my $log = $c->app->log;
    $log->debug("opening a websocket for " . $c->tx->remote_address);

    # enable permessage-deflate
    $c->tx->with_compression;

    $c->inactivity_timeout(120);
    # Increase inactivity timeout for connection a bit
    Mojo::IOLoop->singleton->stream($c->tx->connection)->timeout(120);

    $c->on(
        json => sub {
            my ($c, $p1) = @_;

            my $tag = 'origin:';
            my $data;
            my $send = 1;
            if (ref($p1) eq 'HASH') {

                if (my $origin = $c->req->headers->header("Origin")) {
                    if ($origin =~ /https?:\/\/([a-zA-Z0-9\.]+)$/) {
                        $tag = "origin:$1";
                    }
                }

                $data = _sanity_failed($p1) || __handle($c, $p1, $tag);
                $send = undef unless $data;

                $data->{echo_req} = $p1;
            } else {
                # for invalid call, eg: not json
                $data = {
                    echo_req => {},
                    msg_type => 'error',
                    error    => {
                        message => "Bad Request",
                        code    => "BadRequest"
                    }};
            }
            $data->{version} = 2;

            my $l = length JSON::to_json($data);
            if ($l > 328000) {
                $data = {
                    echo_req => $p1,
                    msg_type => 'error',
                    error    => {
                        message => "Response too large.",
                        code    => "ResponseTooLarge"
                    }};
            }
            $log->info("Call from $tag, " . JSON::to_json(($data->{error}) ? $data : $data->{echo_req}));
            if ($send) {
                $c->send({json => $data});
            } else {
                return;
            }
        });

    # stop all recurring
    $c->on(
        finish => sub {
            my ($c) = @_;
            my $ws_id = $c->tx->connection;
            foreach my $id (keys %{$c->{ws}{$ws_id}}) {
                Mojo::IOLoop->remove($id);
            }
            delete $c->{ws}{$ws_id};
            delete $c->{fmb_ids}{$ws_id};
        });

    return;
}

sub __handle {
    my ($c, $p1, $tag) = @_;

    my $log = $c->app->log;
    $log->debug("websocket got json " . $c->dumper($p1));

    # [param key, sub, require auth, unauth-error-code]
    my @dispatch = (
        ['authorize',              \&BOM::WebSocketAPI::v2::Authorize::authorize,                        0],
        ['ticks',                  \&BOM::WebSocketAPI::v2::MarketDiscovery::ticks,                      0],
        ['proposal',               \&BOM::WebSocketAPI::v2::MarketDiscovery::proposal,                   0],
        ['forget',                 \&BOM::WebSocketAPI::v2::System::forget,                              0],
        ['forget_all',             \&BOM::WebSocketAPI::v2::System::forget_all,                          0],
        ['ping',                   \&BOM::WebSocketAPI::v2::System::ping,                                0],
        ['time',                   \&BOM::WebSocketAPI::v2::System::server_time,                         0],
        ['payout_currencies',      \&BOM::WebSocketAPI::v2::ContractDiscovery::payout_currencies,        0],
        ['active_symbols',         \&BOM::WebSocketAPI::v2::Symbols::active_symbols,                     0],
        ['contracts_for',          \&BOM::WebSocketAPI::v2::ContractDiscovery::contracts_for,            0],
        ['trading_times',          \&BOM::WebSocketAPI::v2::MarketDiscovery::trading_times,              0],
        ['buy',                    \&BOM::WebSocketAPI::v2::PortfolioManagement::buy,                    1],
        ['sell',                   \&BOM::WebSocketAPI::v2::PortfolioManagement::sell,                   1],
        ['portfolio',              \&BOM::WebSocketAPI::v2::PortfolioManagement::portfolio,              1],
        ['proposal_open_contract', \&BOM::WebSocketAPI::v2::PortfolioManagement::proposal_open_contract, 1],
        ['balance',                \&BOM::WebSocketAPI::v2::Accounts::balance,                           1],
        ['statement',              \&BOM::WebSocketAPI::v2::Accounts::statement,                         1],
    );

    foreach my $dispatch (@dispatch) {
        next unless $p1->{$dispatch->[0]};
        my $t0        = [Time::HiRes::gettimeofday];
        my $f         = '/home/git/regentmarkets/bom-websocket-api/config/v2/' . $dispatch->[0];
        my $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/send.json")));
        if (not $validator->validate($p1)) {
            my $result = $validator->validate($p1);
            my $error;
            $error .= " - $_" foreach $result->errors;
            return {
                msg_type => 'error',
                error    => {
                    message => "Input validation failed " . $error,
                    code    => "InputValidationFailed"
                }};
        }

        DataDog::DogStatsd::Helper::stats_inc('websocket_api.call.' . $dispatch->[0], {tags => [$tag]});
        DataDog::DogStatsd::Helper::stats_inc('websocket_api.call.all',               {tags => [$tag]});

        if ($dispatch->[2] and not $c->stash('client')) {
            return __authorize_error($dispatch->[0]);
        }
        my $result = $dispatch->[1]->($c, $p1);

        $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/receive.json")));
        if ($result and not $validator->validate($result)) {
            my $validation_errors = $validator->validate($result);
            my $error;
            $error .= " - $_" foreach $validation_errors->errors;
            warn "Invalid output parameter for [ " . JSON::to_json($result) . " error: $error ]";
            return {
                msg_type => 'error',
                error    => {
                    message => "Output validation failed " . $error,
                    code    => "OutputValidationFailed"
                }}

        }
        $result->{debug} = [Time::HiRes::tv_interval($t0), ($c->stash('client') ? $c->stash('client')->loginid : '')] if ref $result;
        return $result;
    }

    $log->debug("unrecognised request: " . $c->dumper($p1));
    return {
        msg_type => 'error',
        error    => {
            message => "unrecognised request",
            code    => "UnrecognisedRequest"
        }};
}

sub __authorize_error {
    my ($msg_type) = @_;
    return {
        msg_type => $msg_type,
        'error'  => {
            message  => "Must authorize first",
            msg_type => $msg_type,
            code     => "AuthorizationRequired"
        }};
}

sub _sanity_failed {
    my $arg = shift;
    my $failed;
    OUTER:
    foreach my $k (keys %$arg) {
        if ($k !~ /^([A-Za-z0-9_-]{1,25})$/ or (not ref $arg->{$k} and $arg->{$k} !~ /^([\s\.A-Za-z0-9_:+-]{0,256})$/)) {
            $failed = 1;
            warn "Sanity check failed: $k -> " . $arg->{$k};
            last OUTER;
        }
        if (ref $arg->{$k}) {
            foreach my $l (keys %{$arg->{$k}}) {
                if ($l !~ /^([A-Za-z0-9_-]{1,25})$/ or $arg->{$k}->{$l} !~ /^([\s\.A-Za-z0-9_:+-]{0,256})$/) {
                    $failed = 1;
                    warn "Sanity check failed: $l -> " . $arg->{$k}->{$l};
                    last OUTER;
                }
            }
        }
    }
    if ($failed) {
        warn 'Sanity check failed.';
        return {
            msg_type => 'sanity_check',
            error    => {
                message => "Parameters sanity check failed",
                code    => "InvalidParameters"
            }};
    }
    return;
}

1;
