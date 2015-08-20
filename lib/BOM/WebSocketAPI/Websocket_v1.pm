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

sub _authorize_error {
    my ($c, $p1, $msg_type) = @_;
    $c->send({
            json => {
                msg_type  => $msg_type,
                echo_req  => $p1,
                $msg_type => {
                    error => {
                        message => "Must authorize first",
                        code    => "AuthorizationRequired"
                    }}}});
    return;
}

my $json_receiver = sub {
    my ($c, $p1) = @_;
    my $app = $c->app;
    my $log = $app->log;
    $log->debug("websocket got json " . $c->dumper($p1));

    my $source = $c->stash('source');

    if (my $token = $p1->{authorize}) {
        my ($client, $account, $email, $loginid) = BOM::WebSocketAPI::Authorize::authorize($c, $token);
        if (not $client) {
            return $c->send({
                    json => {
                        msg_type  => 'authorize',
                        echo_req  => $p1,
                        authorize => {
                            error => {
                                message => "Token invalid",
                                code    => "InvalidToken"
                            },
                        }}});
        } else {
            return $c->send({
                    json => {
                        msg_type  => 'authorize',
                        echo_req  => $p1,
                        authorize => {
                            fullname => $client->full_name,
                            loginid  => $client->loginid,
                            balance  => ($account ? $account->balance : 0),
                            currency => ($account ? $account->currency_code : ''),
                            email    => $email,
                        }}});
        }
    }

    if (my $id = $p1->{forget}) {
        BOM::WebSocketAPI::System::forget($c, $p1->{forget});
    }

    if ($p1->{payout_currencies}) {
        return $c->send({
                json => {
                    msg_type          => 'payout_currencies',
                    echo_req          => $p1,
                    payout_currencies => BOM::WebSocketAPI::ContractDiscovery::payout_currencies($c)}});
    }

    if (my $options = $p1->{statement}) {
        my $client = $c->stash('client') || return $c->_authorize_error($p1);
        my $results = $c->BOM::WebSocketAPI::Accounts::get_transactions($options);
        return $c->send({
                json => {
                    msg_type  => 'statement',
                    echo_req  => $p1,
                    statement => $results
                }});
    }

    if (my $by = $p1->{active_symbols}) {
        return $c->send({
                json => {
                    msg_type       => 'active_symbols',
                    echo_req       => $p1,
                    active_symbols => BOM::WebSocketAPI::Symbols->active_symbols($by)}});
    }

    if (my $symbol = $p1->{contracts_for}) {
        return $c->send({
                json => {
                    msg_type      => 'contracts_for',
                    echo_req      => $p1,
                    contracts_for => BOM::Product::Contract::Finder::available_contracts_for_symbol($symbol)}});
    }

    if (my $options = $p1->{offerings}) {
        return $c->send({
                json => {
                    msg_type  => 'offerings',
                    echo_req  => $p1,
                    offerings => BOM::WebSocketAPI::Offerings::query($c, $options)}});
    }

    if (my $options = $p1->{trading_times}) {
        my $trading_times = $c->BOM::WebSocketAPI::Offerings::trading_times($options);
        return $c->send({
                json => {
                    msg_type      => 'trading_times',
                    echo_req      => $p1,
                    trading_times => $trading_times,
                }});
    }

    if ($p1->{portfolio}) {
        my $client          = $c->stash('client') || return $c->_authorize_error($p1, 'portfolio');
        my $p0              = {%$p1};
        my $portfolio_stats = BOM::WebSocketAPI::PortfolioManagement::portfolio($c, $p1);
        return $c->send({
                json => {
                    msg_type        => 'portfolio_stats',
                    echo_req        => $p0,
                    portfolio_stats => $portfolio_stats
                }});
    }

    if ($p1->{ticks}) {
        my $json = BOM::WebSocketAPI::MarketDiscovery::ticks($c, $p1);
        return unless $json;
        return $c->send({
                json => {
                    echo_req => $p1,
                    %$json
                }});
    }

    if ($p1->{proposal}) {
        BOM::WebSocketAPI::MarketDiscovery::proposal($c, $p1);
        return;
    }

    if ($p1->{buy}) {
        my $client = $c->stash('client') || return $c->_authorize_error($p1, 'open_receipt');
        my $json = BOM::WebSocketAPI::PortfolioManagement::buy($c, $p1);
        return $c->send({json => $json});
    }

    if ($p1->{sell}) {
        my $client = $c->stash('client') || return $c->_authorize_error($p1, 'close_receipt');
        my $json = BOM::WebSocketAPI::PortfolioManagement::sell($c, $p1);
        return $c->send({json => $json});
    }

    $log->debug("unrecognised request: " . $c->dumper($p1));
    return;
};

sub entry_point {
    my $c   = shift;
    my $app = $c->app;
    my $log = $app->log;
    $log->debug("opening a websocket for " . $c->tx->remote_address);
    $c->inactivity_timeout(600);
    $c->on(json => $json_receiver);
    return;
}

1;

