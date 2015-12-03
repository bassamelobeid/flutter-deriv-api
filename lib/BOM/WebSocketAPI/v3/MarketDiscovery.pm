package BOM::WebSocketAPI::v3::MarketDiscovery;

use strict;
use warnings;

use Try::Tiny;
use Mojo::DOM;
use Time::HiRes;
use Data::UUID;
use List::MoreUtils qw(any none);

use BOM::WebSocketAPI::v3::Utility;
use BOM::WebSocketAPI::v3::Symbols;
use BOM::Market::Registry;
use BOM::Market::Underlying;
use BOM::Platform::Context qw (localize);
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::Contract::Offerings;
use BOM::Product::Contract::Category;
use BOM::Product::Offerings qw(get_offerings_with_filter get_permitted_expiries);

sub trading_times {
    my $args = shift;

    my $date = try { Date::Utility->new($args->{trading_times}) } || Date::Utility->new;
    my $tree = BOM::Product::Contract::Offerings->new(date => $date)->decorate_tree(
        markets     => {name => 'name'},
        submarkets  => {name => 'name'},
        underlyings => {
            name         => 'name',
            times        => 'times',
            events       => 'events',
            symbol       => sub { $_->symbol },
            feed_license => sub { $_->feed_license },
            delay_amount => sub { $_->delay_amount },
        });
    my $trading_times = {};
    for my $mkt (@$tree) {
        my $market = {};
        push @{$trading_times->{markets}}, $market;
        $market->{name} = $mkt->{name};
        for my $sbm (@{$mkt->{submarkets}}) {
            my $submarket = {};
            push @{$market->{submarkets}}, $submarket;
            $submarket->{name} = $sbm->{name};
            for my $ul (@{$sbm->{underlyings}}) {
                push @{$submarket->{symbols}},
                    {
                    name       => $ul->{name},
                    symbol     => $ul->{symbol},
                    settlement => $ul->{settlement} || '',
                    events     => $ul->{events},
                    times      => $ul->{times},
                    ($ul->{feed_license} ne 'realtime') ? (feed_license => $ul->{feed_license}) : (),
                    ($ul->{delay_amount} > 0)           ? (delay_amount => $ul->{delay_amount}) : (),
                    };
            }
        }
    }
    return $trading_times,;
}

sub asset_index {
    my ($language, $args) = @_;

    my $asset_index = BOM::Product::Contract::Offerings->new->decorate_tree(
        markets => {
            code => sub { $_->name },
            name => sub { $_->translated_display_name }
        },
        submarkets => {
            code => sub {
                $_->name;
            },
            name => sub {
                $_->translated_display_name;
            }
        },
        underlyings => {
            code => sub {
                $_->symbol;
            },
            name => sub {
                $_->translated_display_name;
            }
        },
        contract_categories => {
            code => sub {
                $_->code;
            },
            name => sub {
                $_->translated_display_name;
            },
            expiries => sub {
                my $underlying = shift;
                my %offered    = %{
                    get_permitted_expiries({
                            underlying_symbol => $underlying->symbol,
                            contract_category => $_->code,
                        })};

                my @times;
                foreach my $expiry (qw(intraday daily tick)) {
                    if (my $included = $offered{$expiry}) {
                        foreach my $key (qw(min max)) {
                            if ($expiry eq 'tick') {
                                # some tick is set to seconds somehow in this code.
                                # don't want to waste time to figure out how it is set
                                my $tick_count = (ref $included->{$key}) ? $included->{$key}->seconds : $included->{$key};
                                push @times, [$tick_count, $tick_count . 't'];
                            } else {
                                $included->{$key} = Time::Duration::Concise::Localize->new(
                                    interval => $included->{$key},
                                    locale   => $language
                                ) unless (ref $included->{$key});
                                push @times, [$included->{$key}->seconds, $included->{$key}->as_concise_string];
                            }
                        }
                    }
                }
                @times = sort { $a->[0] <=> $b->[0] } @times;
                return +{
                    min => $times[0][1],
                    max => $times[-1][1],
                };
            },
        },
    );

    ## remove obj for json encode
    my @data;
    for my $market (@$asset_index) {
        delete $market->{$_} for (qw/obj children/);
        for my $submarket (@{$market->{submarkets}}) {
            delete $submarket->{$_} for (qw/obj parent_obj children parent/);
            for my $ul (@{$submarket->{underlyings}}) {
                delete $ul->{$_} for (qw/obj parent_obj children parent/);
                for (@{$ul->{contract_categories}}) {
                    $_ = [$_->{code}, $_->{name}, $_->{expiries}->{min}, $_->{expiries}->{max}];
                }
                my $x = [$ul->{code}, $ul->{name}, $ul->{contract_categories}];
                push @data, $x;
            }
        }
    }

    return \@data;
}

sub validate_offering {
    my $symbol = @_;

    my @offerings = get_offerings_with_filter('underlying_symbol');
    if (none { $symbol eq $_ } @offerings) {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => 'InvalidSymbol',
                message_to_client => BOM::Platform::Context::localize("Symbol [_1] invalid", $symbol)});
    }
    my $u = BOM::Market::Underlying->new($symbol);

    if ($u->feed_license ne 'realtime') {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => 'NoRealtimeQuotes',
                message_to_client => BOM::Platform::Context::localize("Realtime quotes not available for [_1]", $symbol)});
    }

    return {status => 1};
}

sub ticks_history {
    my ($symbol, $args) = @_;

    my $ul = BOM::Market::Underlying->new($symbol);

    my $style = $args->{style} || ($args->{granularity} ? 'candles' : 'ticks');

    my ($publish, $result, $type);
    if ($style eq 'ticks') {
        my $ticks = BOM::WebSocketAPI::v3::Symbols::ticks({%$args, ul => $ul});    ## no critic
        my $history = {
            prices => [map { $_->{price} } @$ticks],
            times  => [map { $_->{time} } @$ticks],
        };
        $result  = {history => $history};
        $type    = "history";
        $publish = 'tick';
    } elsif ($style eq 'candles') {
        my @candles = @{BOM::WebSocketAPI::v3::Symbols::candles({%$args, ul => $ul})};    ## no critic
        if (@candles) {
            $result = {
                candles => \@candles,
            };
            $type    = "candles";
            $publish = $args->{granularity};
        } else {
            return BOM::WebSocketAPI::v3::Utility::create_error({
                    code              => 'InvalidCandlesRequest',
                    message_to_client => BOM::Platform::Context::localize('Invalid candles request')});
        }
    } else {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => 'InvalidStyle',
                message_to_client => BOM::Platform::Context::localize("Style [_1] invalid", $style)});
    }

    return {
        type    => $type,
        data    => $result,
        publish => $publish
    };
}

sub prepare_ask {
    my $p1 = shift;
    my %p2 = %$p1;

    $p2{date_start} //= 0;
    if ($p2{date_expiry}) {
        $p2{fixed_expiry} //= 1;
    }

    if (defined $p2{barrier} && defined $p2{barrier2}) {
        $p2{low_barrier}  = delete $p2{barrier2};
        $p2{high_barrier} = delete $p2{barrier};
    } elsif ($p1->{contract_type} !~ /^(SPREAD|ASIAN)/) {
        $p2{barrier} //= 'S0P';
        delete $p2{barrier2};
    }

    $p2{underlying}  = delete $p2{symbol};
    $p2{bet_type}    = delete $p2{contract_type};
    $p2{amount_type} = delete $p2{basis} if exists $p2{basis};
    if ($p2{duration} and not exists $p2{date_expiry}) {
        $p2{duration} .= delete $p2{duration_unit};
    }

    return \%p2;
}

sub get_ask {
    my $p2 = shift;
    my $contract = try { produce_contract({%$p2}) } || do {
        my $err = $@;
        return {
            error => {
                message => BOM::Platform::Context::localize("Cannot create contract"),
                code    => "ContractCreationFailure"
            }};
    };
    if (!$contract->is_valid_to_buy) {
        if (my $pve = $contract->primary_validation_error) {
            return {
                error => {
                    message => $pve->message_to_client,
                    code    => "ContractBuyValidationError"
                },
                longcode  => Mojo::DOM->new->parse($contract->longcode)->all_text,
                ask_price => sprintf('%.2f', $contract->ask_price),
            };
        }
        return {
            error => {
                message => BOM::Platform::Context::localize("Cannot validate contract"),
                code    => "ContractValidationError"
            }};
    }

    my $ask_price = sprintf('%.2f', $contract->ask_price);
    my $display_value = $contract->is_spread ? $contract->buy_level : $ask_price;

    my $response = {
        longcode      => Mojo::DOM->new->parse($contract->longcode)->all_text,
        payout        => $contract->payout,
        ask_price     => $ask_price,
        display_value => $display_value,
        spot          => $contract->current_spot,
        spot_time     => $contract->current_tick->epoch,
        date_start    => $contract->date_start->epoch
    };
    $response->{spread} = $contract->spread if $contract->is_spread;

    return $response;
}

1;
