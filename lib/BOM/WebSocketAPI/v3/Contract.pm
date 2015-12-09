package BOM::WebSocketAPI::v3::Contract;

use strict;
use warnings;

use BOM::WebSocketAPI::v3::Utility;
use BOM::Market::Underlying;
use BOM::Platform::Context qw (localize);
use BOM::Product::Offerings qw(get_offerings_with_filter);
use BOM::Product::ContractFactory qw(produce_contract);

sub validate_symbol {
    my $symbol    = shift;
    my @offerings = get_offerings_with_filter('underlying_symbol');
    if (none { $symbol eq $_ } @offerings) {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => 'InvalidSymbol',
                message_to_client => BOM::Platform::Context::localize("Symbol [_1] invalid", $symbol)});
    }
    return;
}

sub validate_license {
    my $symbol = shift;
    my $u      = BOM::Market::Underlying->new($symbol);

    if ($u->feed_license ne 'realtime') {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => 'NoRealtimeQuotes',
                message_to_client => BOM::Platform::Context::localize("Realtime quotes not available for [_1]", $symbol)});
    }
    return;
}

sub validate_underlying {
    my $symbol = shift;

    my $response = validate_symbol($symbol);
    return $response if $response;

    $response = validate_license($symbol);
    return $response if $response;

    return {status => 1};
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
                longcode  => $contract->longcode,
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
        longcode      => $contract->longcode,
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
