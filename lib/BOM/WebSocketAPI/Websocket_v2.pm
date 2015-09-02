package BOM::WebSocketAPI::Websocket_v2;

use Mojo::Base 'BOM::WebSocketAPI::v2::BaseController';

use BOM::WebSocketAPI::v2::Symbols;
use BOM::WebSocketAPI::v2::Offerings;
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
            $data->{version} = 2;

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
        ['authorize',         \&BOM::WebSocketAPI::v2::Authorize::authorize,                 0],
        ['ticks',             \&BOM::WebSocketAPI::v2::MarketDiscovery::ticks,               0],
        ['proposal',          \&BOM::WebSocketAPI::v2::MarketDiscovery::proposal,            0],
        ['forget',            \&BOM::WebSocketAPI::v2::System::forget,                       0],
        ['ping',              \&BOM::WebSocketAPI::v2::System::ping,                         0],
        ['time',              \&BOM::WebSocketAPI::v2::System::server_time,                  0],
        ['payout_currencies', \&BOM::WebSocketAPI::v2::ContractDiscovery::payout_currencies, 0],
        ['active_symbols',    \&BOM::WebSocketAPI::v2::Symbols::active_symbols,              0],
        ['contracts_for',     \&BOM::WebSocketAPI::v2::ContractDiscovery::contracts_for,     0],
        ['offerings',         \&BOM::WebSocketAPI::v2::Offerings::offerings,                 0],
        ['trading_times',     \&BOM::WebSocketAPI::v2::Offerings::trading_times,             0],
        ['buy',               \&BOM::WebSocketAPI::v2::PortfolioManagement::buy,             1],
        ['sell',              \&BOM::WebSocketAPI::v2::PortfolioManagement::sell,            1],
        ['portfolio',         \&BOM::WebSocketAPI::v2::PortfolioManagement::portfolio,       1],
        ['balance',           \&BOM::WebSocketAPI::v2::Accounts::balance,                    1],
        ['statement',         \&BOM::WebSocketAPI::v2::Accounts::statement,                  1],
    );

    foreach my $dispatch (@dispatch) {
        next unless $p1->{$dispatch->[0]};
        my $f         = '/home/git/regentmarkets/bom-websocket-api/config/v2/' . $dispatch->[0];
        my $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/send.json")));
        if ($dispatch->[0] ne 'statement' and not $validator->validate($p1)) {
            die "Invalid input parameter for [" . $dispatch->[0] . "]";
        }

        my $tag = 'origin:';
        if (my $origin = $c->req->headers->header("Origin")) {
            if ($origin =~ /https?:\/\/([a-zA-Z0-9\.]+)$/) {
                $tag = "origin:$1";
            }
        }
        DataDog::DogStatsd::Helper::stats_inc('websocket_api.call.' . $dispatch->[0], {tags => [$tag]});
        DataDog::DogStatsd::Helper::stats_inc('websocket_api.call.all',               {tags => [$tag]});

        if ($dispatch->[2] and not $c->stash('client')) {
            return __authorize_error($dispatch->[0]);
        }
        my $result = $dispatch->[1]->($c, $p1);

#        $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/receive.json")));
#        if (not $validator->validate($result)) {
#            die "Invalid results parameters.";
#        }

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
