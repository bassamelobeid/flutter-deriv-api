package BOM::RPC::v3::Contract;

use strict;
use warnings;

use Try::Tiny;
use List::MoreUtils qw(none);

use BOM::RPC::v3::Utility;
use BOM::Market::Underlying;
use BOM::Platform::Context qw (localize);
use BOM::Product::Offerings qw(get_offerings_with_filter);
use BOM::Product::ContractFactory qw(produce_contract);

sub validate_symbol {
    my $symbol    = shift;
    my @offerings = get_offerings_with_filter('underlying_symbol');
    if (none { $symbol eq $_ } @offerings) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidSymbol',
                message_to_client => BOM::Platform::Context::localize("Symbol [_1] invalid", $symbol)});
    }
    return;
}

sub validate_license {
    my $symbol = shift;
    my $u      = BOM::Market::Underlying->new($symbol);

    if ($u->feed_license ne 'realtime') {
        return BOM::RPC::v3::Utility::create_error({
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

sub get_bid {
    my ($short_code, $contract_id, $currency) = @_;

    my $contract = produce_contract($short_code, $currency);

    my %returnhash = (
        ask_price           => sprintf('%.2f', $contract->ask_price),
        bid_price           => sprintf('%.2f', $contract->bid_price),
        current_spot_time   => $contract->current_tick->epoch,
        contract_id         => $contract_id,
        underlying          => $contract->underlying->symbol,
        is_expired          => $contract->is_expired,
        is_valid_to_sell    => $contract->is_valid_to_sell,
        is_forward_starting => $contract->is_forward_starting,
        is_path_dependent   => $contract->is_path_dependent,
        is_intraday         => $contract->is_intraday,
        date_start          => $contract->date_start->epoch,
        date_expiry         => $contract->date_expiry->epoch,
        date_settlement     => $contract->date_settlement->epoch,
        currency            => $contract->currency,
        longcode            => $contract->longcode,
        shortcode           => $contract->shortcode,
        payout              => $contract->payout,
    );

    if (not $contract->is_valid_to_sell) {
        $returnhash{validation_error} = $contract->primary_validation_error->message_to_client;
    }

    if ($contract->is_spread) {
        return \%returnhash;
    }

    if ($contract->expiry_type eq 'tick') {
        $returnhash{prediction}      = $contract->prediction;
        $returnhash{tick_count}      = $contract->tick_count;
        $returnhash{entry_tick}      = $contract->entry_tick ? $contract->entry_tick->quote : '';
        $returnhash{entry_tick_time} = $contract->entry_tick ? $contract->entry_tick->epoch : '';
        $returnhash{exit_tick}       = $contract->exit_tick ? $contract->exit_tick->quote : '';
        $returnhash{exit_tick_time}  = $contract->exit_tick ? $contract->exit_tick->epoch : '';
    } else {
        $returnhash{current_spot} = $contract->current_spot;
        $returnhash{entry_spot}   = $contract->entry_spot;
    }

    if ($contract->two_barriers) {
        $returnhash{high_barrier} = $contract->high_barrier->as_absolute;
        $returnhash{low_barrier}  = $contract->low_barrier->as_absolute;
    } elsif ($contract->barrier) {
        $returnhash{barrier} = $contract->barrier->as_absolute;
    }

    return \%returnhash;
}

sub send_ask {
    my $params = shift;
    my $args   = $params->{args};

    my %details  = %{$args};
    my $response = BOM::RPC::v3::Contract::get_ask(BOM::RPC::v3::Contract::prepare_ask(\%details));
    if ($response->{error}) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'pricing error',
            message_to_client => BOM::Platform::Locale::error_map()->{'pricing error'},
            details           => $response
        });
    }
    return {
        msg_type => 'proposal',
        echo_req => $args,
        (exists $args->{req_id}) ? (req_id => $args->{req_id}) : (),
        proposal => {
            id => $id,
            %$response
        }};
}
1;
