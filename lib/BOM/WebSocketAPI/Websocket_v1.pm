package BOM::WebSocketAPI::Websocket_v1;

use Mojo::Base 'BOM::WebSocketAPI::v1::BaseController';

use BOM::WebSocketAPI::v1::Symbols;
use BOM::WebSocketAPI::v1::Offerings;
use BOM::WebSocketAPI::v1::Authorize;
use BOM::WebSocketAPI::v1::ContractDiscovery;
use BOM::WebSocketAPI::v1::System;
use BOM::WebSocketAPI::v1::Accounts;
use BOM::WebSocketAPI::v1::MarketDiscovery;
use BOM::WebSocketAPI::v1::PortfolioManagement;
use DataDog::DogStatsd::Helper;

sub ok {
    my $c      = shift;
    my $source = 1;       # check http origin here
    $c->stash(source => $source);
    return 1;
}

sub entry_point {
    my $c = shift;

    my $log = $c->app->log;
    $log->debug("opening a websocket for " . $c->tx->remote_address);

    $c->inactivity_timeout(600);
    $c->on(
        json => sub {
            my ($c, $p1) = @_;

            my $data;
            if (ref($p1) eq 'HASH') {
                $data = _sanity_failed($p1) || __handle($c, $p1);
                return unless $data;

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

            my $l = length JSON::to_json($data);
            if ($l > 128000) {
                die "data too large [$l]";
            }
            $c->send({json => $data});
        });
    return;
}

sub __handle {
    my ($c, $p1) = @_;

    my $log = $c->app->log;
    $log->debug("websocket got json " . $c->dumper($p1));

    # [param key, sub, require auth, unauth-error-code]
    my @dispatch = (
        ['authorize',         \&BOM::WebSocketAPI::v1::Authorize::authorize,                 0],
        ['ticks',             \&BOM::WebSocketAPI::v1::MarketDiscovery::ticks,               0],
        ['proposal',          \&BOM::WebSocketAPI::v1::MarketDiscovery::proposal,            0],
        ['forget',            \&BOM::WebSocketAPI::v1::System::forget,                       0],
        ['ping',              \&BOM::WebSocketAPI::v1::System::ping,                         0],
        ['payout_currencies', \&BOM::WebSocketAPI::v1::ContractDiscovery::payout_currencies, 0],
        ['active_symbols',    \&BOM::WebSocketAPI::v1::Symbols::active_symbols,              0],
        ['contracts_for',     \&BOM::WebSocketAPI::v1::ContractDiscovery::contracts_for,     0],
        ['offerings',         \&BOM::WebSocketAPI::v1::Offerings::offerings,                 0],
        ['trading_times',     \&BOM::WebSocketAPI::v1::Offerings::trading_times,             0],
        ['buy',       \&BOM::WebSocketAPI::v1::PortfolioManagement::buy,       1, 'open_receipt'],
        ['sell',      \&BOM::WebSocketAPI::v1::PortfolioManagement::sell,      1, 'close_receipt'],
        ['portfolio', \&BOM::WebSocketAPI::v1::PortfolioManagement::portfolio, 1],
        ['balance',   \&BOM::WebSocketAPI::v1::Accounts::balance,              1],
        ['statement', \&BOM::WebSocketAPI::v1::Accounts::statement,            1],
    );

    foreach my $dispatch (@dispatch) {
        next unless $p1->{$dispatch->[0]};
        my $tag = 'origin:';
        if (my $origin = $c->req->headers->header("Origin")) {
            if ($origin =~ /https?:\/\/([a-zA-Z0-9\.]+)$/) {
                $tag = "origin:$1";
            }
        }
        DataDog::DogStatsd::Helper::stats_inc('websocket_api.call.' . $dispatch->[0], {tags => [$tag]});
        DataDog::DogStatsd::Helper::stats_inc('websocket_api.call.all',               {tags => [$tag]});

        if ($dispatch->[2] and not $c->stash('client')) {
            return __authorize_error($dispatch->[3] || $dispatch->[0]);
        }
        return $dispatch->[1]->($c, $p1);
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
        if ($k !~ /^([A-Za-z0-9_-]{1,25})$/ or (not ref $arg->{$k} and $arg->{$k} !~ /^([A-Za-z0-9_-]{1,50})$/)) { $failed = 1; last OUTER; }
        if (ref $arg) {
            foreach my $l (keys %$arg) {
                if ($k !~ /^([A-Za-z0-9_-]{1,25})$/ or $arg->{$k} !~ /^([A-Za-z0-9_-]{1,50})$/) { $failed = 1; last OUTER; }
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
