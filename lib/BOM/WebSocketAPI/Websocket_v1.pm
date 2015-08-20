package BOM::WebSocketAPI::Websocket_v1;

use Mojo::Base 'BOM::WebSocketAPI::BaseController';

use Mojo::DOM;

use Try::Tiny;

use BOM::Platform::Client;
use BOM::Product::Transaction;
use BOM::Product::Contract::Finder;
use BOM::Product::Contract::Offerings;
use BOM::Product::ContractFactory qw(produce_contract make_similar_contract);

use BOM::WebSocketAPI::Symbols;
use BOM::WebSocketAPI::Offerings;
use BOM::WebSocketAPI::Authorize;
use BOM::WebSocketAPI::ContractDiscovery;
use BOM::WebSocketAPI::System;
use BOM::WebSocketAPI::Accounts;
use BOM::WebSocketAPI::MarketDiscovery;
use BOM::WebSocketAPI::PortfolioManagement;

my $DOM = Mojo::DOM->new;

sub ok {
    my $c      = shift;
    my $source = 1;       # check http origin here
    $c->stash(source => $source);
    return 1;
}

sub prepare_ask {
    my ($c, $p1) = @_;

    my $app = $c->app;
    my $log = $app->log;

    $log->debug("prepare_ask got p1 " . $c->dumper($p1));

    # this has two deliverables:
    # 1) apply default values inline to the given $p1,
    # 2) return a manipulated copy suitable for produce_contract

    $p1->{contract_type} //= 'CALL';
    $p1->{symbol}        //= 'R_100';
    $p1->{basis}         //= 'payout';
    $p1->{amount_val}    //= 10;
    $p1->{currency}      //= 'USD';
    $p1->{date_start}    //= 0;
    if ($p1->{date_expiry}) {
        $p1->{fixed_expiry} //= 1;
    } else {
        $p1->{duration}      //= 15;
        $p1->{duration_unit} //= 's';
    }
    my %p2 = %$p1;

    if (defined $p2{barrier} && defined $p2{barrier2}) {
        $p2{low_barrier}  = delete $p2{barrier2};
        $p2{high_barrier} = delete $p2{barrier};
    } else {
        $p2{barrier} //= 'S0P';
        delete $p2{barrier2};
    }

    $p2{underlying}  = delete $p2{symbol};
    $p2{bet_type}    = delete $p2{contract_type};
    $p2{amount_type} = delete $p2{basis};
    $p2{amount}      = delete $p2{amount_val};
    $p2{duration} .= delete $p2{duration_unit} unless $p2{date_expiry};

    return \%p2;
}

sub get_ask {
    my ($c, $p2) = @_;
    my $app      = $c->app;
    my $log      = $app->log;
    my $contract = try { produce_contract({%$p2}) } || do {
        my $err = $@;
        $log->info("contract creation failure: $err");
        return {
            error => {
                message => "cannot create contract",
                code    => "ContractCreationFailure"
            }};
    };
    if (!$contract->is_valid_to_buy) {
        if (my $pve = $contract->primary_validation_error) {
            $log->error("primary error: " . $pve->message);
            return {
                error => {
                    message => $pve->message_to_client,
                    code    => "ContractBuyValidationError"
                },
                longcode  => $DOM->parse($contract->longcode)->all_text,
                ask_price => sprintf('%.2f', $contract->ask_price),
            };
        }
        $log->error("contract invalid but no error!");
        return {
            error => {
                message => "cannot validate contract",
                code    => "ContractValidationError"
            }};
    }
    return {
        longcode   => $DOM->parse($contract->longcode)->all_text,
        payout     => $contract->payout,
        ask_price  => sprintf('%.2f', $contract->ask_price),
        bid_price  => sprintf('%.2f', $contract->bid_price),
        spot       => $contract->current_spot,
        spot_time  => $contract->current_tick->epoch,
        date_start => $contract->date_start->epoch,
    };
}

sub send_ask {
    my ($c, $id, $p1, $p2) = @_;
    my $latest = $c->get_ask($p2);
    if ($latest->{error}) {
        Mojo::IOLoop->remove($id);
        delete $c->{$id};
    }
    $c->send({
            json => {
                msg_type => 'proposal',
                echo_req => $p1,
                proposal => {
                    id => $id,
                    %$latest
                }}});
    return;
}

sub prepare_bid {
    my ($c, $p1) = @_;
    my $app      = $c->app;
    my $log      = $app->log;
    my $fmb      = delete $p1->{fmb};
    my $currency = $fmb->account->currency_code;
    my $contract = produce_contract($fmb->short_code, $currency);
    %$p1 = (
        fmb_id        => $fmb->id,
        purchase_time => $fmb->purchase_time->epoch,
        symbol        => $fmb->underlying_symbol,
        payout        => $fmb->payout_price,
        buy_price     => $fmb->buy_price,
        date_start    => $fmb->start_time->epoch,
        expiry_time   => $fmb->expiry_time->epoch,
        contract_type => $fmb->bet_type,
        currency      => $currency,
        longcode      => $DOM->parse($contract->longcode)->all_text,
    );
    return {
        fmb      => $fmb,
        contract => $contract,
    };
}

sub get_bid {
    my ($c, $p2) = @_;
    my $app = $c->app;
    my $log = $app->log;

    my @similar_args = ($p2->{contract}, {priced_at => 'now'});
    my $contract = try { make_similar_contract(@similar_args) } || do {
        my $err = $@;
        $log->info("contract for sale creation failure: $err");
        return {
            error => {
                message => "cannot create sell contract",
                code    => "ContractSellCreateError"
            }};
    };
    if (!$contract->is_valid_to_sell) {
        $log->error("primary error: " . $contract->primary_validation_error->message);
        return {
            error => {
                message => $contract->primary_validation_error->message_to_client,
                code    => "ContractSellValidationError"
            }};
    }

    return {
        ask_price => sprintf('%.2f', $contract->ask_price),
        bid_price => sprintf('%.2f', $contract->bid_price),
        spot      => $contract->current_spot,
        spot_time => $contract->current_tick->epoch,
    };
}

sub send_bid {
    my ($c, $id, $p0, $p1, $p2) = @_;
    my $latest = $c->get_bid($p2);
    if ($latest->{error}) {
        Mojo::IOLoop->remove($id);
        delete $c->{$id};
        delete $c->{fmb_ids}{$p2->{fmb}->id};
    }
    $c->send({
            json => {
                msg_type  => 'portfolio',
                echo_req  => $p0,
                portfolio => {
                    id => $id,
                    %$p1,
                    %$latest
                }}});
    return;
}

sub send_tick {
    my ($c, $id, $p1, $ul) = @_;
    my $tick = $ul->get_combined_realtime;
    if ($tick->{epoch} > ($c->{$id}{epoch} || 0)) {
        $c->send({
                json => {
                    msg_type => 'tick',
                    echo_req => $p1,
                    tick     => {
                        id    => $id,
                        epoch => $tick->{epoch},
                        quote => $tick->{quote}}}});
        $c->{$id}{epoch} = $tick->{epoch};
    }
    return;
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
        return $c->send({
                json => {
                    msg_type => 'forget',
                    echo_req => $p1,
                    forget   => BOM::WebSocketAPI::System::forget($c, $id),
                }});
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
        return $c->send({
                json => {
                    msg_type  => 'statement',
                    echo_req  => $p1,
                    statement => BOM::WebSocketAPI::Accounts::get_transactions($c, $options),
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
        return $c->send({
                json => {
                    msg_type      => 'trading_times',
                    echo_req      => $p1,
                    trading_times => BOM::WebSocketAPI::Offerings::trading_times($c, $options),
                }});
    }

    if ($p1->{portfolio}) {
        my $client = $c->stash('client') || return $c->_authorize_error($p1, 'portfolio');
        return $c->send({
                json => {
                    msg_type        => 'portfolio',
                    echo_req        => $p1,
                    portfolio_stats => BOM::WebSocketAPI::PortfolioManagement::portfolio($c, $p1),
                }});
    }

    if ($p1->{ticks}) {
        my $json = BOM::WebSocketAPI::MarketDiscovery::ticks($c, $p1);
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

