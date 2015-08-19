package BOM::WebSocketAPI::MarketDiscovery;

use strict;
use warnings;

use BOM::WebSocketAPI::Symbols;

use BOM::Market::Underlying;
use BOM::Product::ContractFactory;

sub ticks {
    my ($c, $args) = @_;

    my $symbol = $args->{ticks};
    my $ul = BOM::Market::Underlying->new($symbol) or return {
        msg_type => 'tick',
        tick     => {
            error => {
                message => "symbol $symbol invalid",
                code    => "InvalidSymbol"
            }
        }
    };

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
            my $candles = $c->BOM::WebSocketAPI::Symbols::_candles({%$args, ul => $ul}) or return {    ## no critic
                msg_type => 'candles',
                candles  => {
                    error => {
                        message => 'invalid candles request',
                        code    => 'InvalidCandlesRequest'
                    }
                }
            };
            return {
                msg_type => 'candles',
                candles  => $candles
            };
        } else {
            return {
                msg_type => 'tick',
                tick     => {
                    error => {
                        message => "style $style invalid",
                        code    => "InvalidStyle"
                    }
                }
            };
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
                }
            }
        };
    }
}

1;

