package BOM::WebSocketAPI::MarketDiscovery;

use strict;
use warnings;

use BOM::WebSocketAPI::Symbols;

use BOM::Market::Underlying;

sub ticks {
    my ($c, $args) = @_;

    my $symbol = $args->{ticks};
    my $ul     = BOM::Market::Underlying->new($symbol)
        or return {
        msg_type => 'tick',
        tick     => {
            error => {
                message => "symbol $symbol invalid",
                code    => "InvalidSymbol"
            }}};

    if ($args->{end}) {
        my $style = $args->{style} || ($args->{granularity} ? 'candles' : 'ticks');
        if ($style eq 'ticks') {
            my $ticks = $c->BOM::WebSocketAPI::Symbols::_ticks({%$args, ul => $ul});    ## no critic
            my $history = {
                prices => [map { $_->{price} } @$ticks],
                times  => [map { $_->{time} } @$ticks],
            };
            return {
                msg_type => 'history',
                history  => $history
            };
        } elsif ($style eq 'candles') {
            my $sender = sub {
                my $candles = shift;
                $c->send({
                        json => {
                            msg_type => 'candles',
                            echo_req => $args,
                            candles  => $candles
                        }});
            };

            if (
                my $watcher = $c->BOM::WebSocketAPI::Symbols::_candles({
                        %$args,    ## no critic
                        ul     => $ul,
                        sender => $sender
                    }))
            {
                # keep this reference; otherwise it goes out of scope early and the job will self-destroy.
                push @{$c->stash->{watchers}}, $watcher;
                $c->on(finish => sub { $c->stash->{feeder}->_pg->destroy });
                return;
            }

            return {
                msg_type => 'candles',
                candles  => {
                    error => {
                        message => 'invalid candles request',
                        code    => 'InvalidCandlesRequest'
                    }}};
        } else {
            return {
                msg_type => 'tick',
                tick     => {
                    error => {
                        message => "style $style invalid",
                        code    => "InvalidStyle"
                    }}};
        }
    }
    if ($ul->feed_license eq 'realtime') {
        my $id;
        $id = Mojo::IOLoop->recurring(1 => sub { $c->send_tick($id, $args, $ul) });
        $c->send_tick($id, $args, $ul);
        $c->on(finish => sub { Mojo::IOLoop->remove($id); delete $c->{$id} });
        return 0;
    } else {
        return {
            msg_type => 'tick',
            tick     => {
                error => {
                    message => "realtime quotes not available",
                    code    => "NoRealtimeQuotes"
                }}};
    }
}

sub proposal {
    my ($c, $args) = @_;

    # this is a recurring contract-price watch ("price streamer")
    # p2 is a manipulated copy of p1 suitable for produce_contract.
    my $p2 = $c->prepare_ask($args);
    my $id;
    $id = Mojo::IOLoop->recurring(1 => sub { $c->send_ask($id, {}, $p2) });
    $c->{$id} = $p2;
    $c->send_ask($id, $args, $p2);
    $c->on(finish => sub { Mojo::IOLoop->remove($id); delete $c->{$id} });

    return;
}

1;

