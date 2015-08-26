package BOM::WebSocketAPI::Websocket_v1;

use Mojo::Base 'BOM::WebSocketAPI::BaseController';

use BOM::WebSocketAPI::Symbols;
use BOM::WebSocketAPI::Offerings;
use BOM::WebSocketAPI::Authorize;
use BOM::WebSocketAPI::ContractDiscovery;
use BOM::WebSocketAPI::System;
use BOM::WebSocketAPI::Accounts;
use BOM::WebSocketAPI::MarketDiscovery;
use BOM::WebSocketAPI::PortfolioManagement;
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
            } else {
                # for invalid call, eg: not json
                $data = {
                    msg_type => 'error',
                    error    => {
                        message => "Bad Request",
                        code    => "BadRequest"
                    }};
            }

            $data->{echo_req} = $p1;
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
        ['authorize',         \&BOM::WebSocketAPI::Authorize::authorize,                 0],
        ['ticks',             \&BOM::WebSocketAPI::MarketDiscovery::ticks,               0],
        ['proposal',          \&BOM::WebSocketAPI::MarketDiscovery::proposal,            0],
        ['forget',            \&BOM::WebSocketAPI::System::forget,                       0],
        ['ping',              \&BOM::WebSocketAPI::System::ping,                         0],
        ['payout_currencies', \&BOM::WebSocketAPI::ContractDiscovery::payout_currencies, 0],
        ['active_symbols',    \&BOM::WebSocketAPI::Symbols::active_symbols,              0],
        ['contracts_for',     \&BOM::WebSocketAPI::ContractDiscovery::contracts_for,     0],
        ['offerings',         \&BOM::WebSocketAPI::Offerings::offerings,                 0],
        ['trading_times',     \&BOM::WebSocketAPI::Offerings::trading_times,             0],
        ['buy',       \&BOM::WebSocketAPI::PortfolioManagement::buy,       1, 'open_receipt'],
        ['sell',      \&BOM::WebSocketAPI::PortfolioManagement::sell,      1, 'close_receipt'],
        ['portfolio', \&BOM::WebSocketAPI::PortfolioManagement::portfolio, 1],
        ['statement', \&BOM::WebSocketAPI::Accounts::statement,            1],
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
        if ($k !~ /([A-Za-z0-9_-]+)/ or (not ref $arg->{$k} and $arg->{$k} !~ /([A-Za-z0-9_\-@\.]+)/)) { $failed = 1; last OUTER; }
        if (ref $arg) {
            foreach my $l (keys %$arg) {
                if ($k !~ /([A-Za-z0-9_-]+)/ or $arg->{$k} !~ /([A-Za-z0-9_\-@\.]+)/) { $failed = 1; last OUTER; }
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
