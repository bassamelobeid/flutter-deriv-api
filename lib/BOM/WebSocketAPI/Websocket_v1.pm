package BOM::WebSocketAPI::Websocket_v1;

use Mojo::Base 'BOM::WebSocketAPI::BaseController';

use Try::Tiny;

use BOM::Product::Contract::Finder;

use BOM::WebSocketAPI::Symbols;
use BOM::WebSocketAPI::Offerings;
use BOM::WebSocketAPI::Authorize;
use BOM::WebSocketAPI::ContractDiscovery;
use BOM::WebSocketAPI::System;
use BOM::WebSocketAPI::Accounts;
use BOM::WebSocketAPI::MarketDiscovery;
use BOM::WebSocketAPI::PortfolioManagement;

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

            my $data = __handle($c, $p1);
            return unless $data;

            $data->{echo_req} = $p1;
            $c->send({json => $data});
        });
    return;
}

sub __handle {
    my ($c, $p1) = @_;

    my $log = $c->app->log;
    $log->debug("websocket got json " . $c->dumper($p1));

    my $source = $c->stash('source');

    if (my $token = $p1->{authorize}) {
        my ($client, $account, $email, $loginid) = BOM::WebSocketAPI::Authorize::authorize($c, $token);
        if (not $client) {
            return {
                msg_type  => 'authorize',
                authorize => {
                    error => {
                        message => "Token invalid",
                        code    => "InvalidToken"
                    },
                }};
        } else {
            return {
                msg_type  => 'authorize',
                authorize => {
                    fullname => $client->full_name,
                    loginid  => $client->loginid,
                    balance  => ($account ? $account->balance : 0),
                    currency => ($account ? $account->currency_code : ''),
                    email    => $email,
                }};
        }
    }

    if (my $id = $p1->{forget}) {
        return {
            msg_type => 'forget',
            forget   => BOM::WebSocketAPI::System::forget($c, $id),
        };
    }

    if ($p1->{payout_currencies}) {
        return {
            msg_type          => 'payout_currencies',
            payout_currencies => BOM::WebSocketAPI::ContractDiscovery::payout_currencies($c)};
    }

    if (my $options = $p1->{statement}) {
        my $client = $c->stash('client') || return __authorize_error('statement');
        return {
            msg_type  => 'statement',
            statement => BOM::WebSocketAPI::Accounts::get_transactions($c, $options),
        };
    }

    if (my $by = $p1->{active_symbols}) {
        return {
            msg_type       => 'active_symbols',
            active_symbols => BOM::WebSocketAPI::Symbols->active_symbols($by)};
    }

    if (my $symbol = $p1->{contracts_for}) {
        return {
            msg_type      => 'contracts_for',
            contracts_for => BOM::Product::Contract::Finder::available_contracts_for_symbol($symbol)};
    }

    if (my $options = $p1->{offerings}) {
        return {
            msg_type  => 'offerings',
            offerings => BOM::WebSocketAPI::Offerings::query($c, $options)};
    }

    if (my $options = $p1->{trading_times}) {
        return {
            msg_type      => 'trading_times',
            trading_times => BOM::WebSocketAPI::Offerings::trading_times($c, $options),
        };
    }

    if ($p1->{portfolio}) {
        my $client = $c->stash('client') || return __authorize_error('portfolio');
        return {
            msg_type        => 'portfolio',
            portfolio_stats => BOM::WebSocketAPI::PortfolioManagement::portfolio($c, $p1),
        };
    }

    if ($p1->{ticks}) {
        if (my $json = BOM::WebSocketAPI::MarketDiscovery::ticks($c, $p1)) {
            return $json;
        }
        return;
    }

    if ($p1->{proposal}) {
        BOM::WebSocketAPI::MarketDiscovery::proposal($c, $p1);
        return;
    }

    if ($p1->{buy}) {
        my $client = $c->stash('client') || return __authorize_error('open_receipt');
        my $json = BOM::WebSocketAPI::PortfolioManagement::buy($c, $p1);
        return $json;
    }

    if ($p1->{sell}) {
        my $client = $c->stash('client') || return __authorize_error('close_receipt');
        my $json = BOM::WebSocketAPI::PortfolioManagement::sell($c, $p1);
        return $json;
    }

    $log->debug("unrecognised request: " . $c->dumper($p1));
    return;
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

1;
