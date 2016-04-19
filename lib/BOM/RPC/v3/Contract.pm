package BOM::RPC::v3::Contract;

use strict;
use warnings;

use Try::Tiny;
use List::MoreUtils qw(none);

use BOM::RPC::v3::Utility;
use BOM::Market::Underlying;
use BOM::Platform::Context qw (localize request);
use BOM::Product::Offerings qw(get_offerings_with_filter);
use BOM::Product::ContractFactory qw(produce_contract);
use Time::HiRes;
use DataDog::DogStatsd::Helper qw(stats_timing);

my %name_mapper = (
    DVD_CASH   => localize('Cash Dividend'),
    DVD_STOCK  => localize('Stock Dividend'),
    STOCK_SPLT => localize('Stock Split'),
);

sub validate_symbol {
    my $symbol    = shift;
    my @offerings = get_offerings_with_filter('underlying_symbol');
    if (!$symbol || none { $symbol eq $_ } @offerings) {
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

sub _get_ask {
    my $p2 = shift;

    my $response;
    try {
        my $tv       = [Time::HiRes::gettimeofday];
        my $contract = produce_contract({%$p2});

        if (!$contract->is_valid_to_buy) {
            if (my $pve = $contract->primary_validation_error) {
                $response = BOM::RPC::v3::Utility::create_error({
                    message_to_client => $pve->message_to_client,
                    code              => "ContractBuyValidationError"
                });
            } else {
                $response = BOM::RPC::v3::Utility::create_error({
                    message_to_client => localize("Cannot validate contract"),
                    code              => "ContractValidationError"
                });
            }
        } else {
            my $ask_price = sprintf('%.2f', $contract->ask_price);
            my $display_value = $contract->is_spread ? $contract->buy_level : $ask_price;

            $response = {
                longcode      => $contract->longcode,
                payout        => $contract->payout,
                ask_price     => $ask_price,
                display_value => $display_value,
                spot_time     => $contract->current_tick->epoch,
                date_start    => $contract->date_start->epoch
            };
            if ($contract->underlying->feed_license eq 'realtime') {
                $response->{spot} = $contract->current_spot;
            }
            $response->{spread} = $contract->spread if $contract->is_spread;
        }
        my $pen = $contract->pricing_engine_name;
        $pen =~ s/::/_/g;
        stats_timing('compute_price.buy.timing', 1000 * Time::HiRes::tv_interval($tv), {tags => ["pricing_engine:$pen"]});
    }
    catch {
        $response = BOM::RPC::v3::Utility::create_error({
            message_to_client => BOM::Platform::Context::localize("Cannot create contract"),
            code              => "ContractCreationFailure"
        });
    };

    return $response;
}

sub get_corporate_actions {
    my $params = shift;
    my ($short_code, $contract_id, $currency, $is_sold) = @{$params}{qw/short_code contract_id currency is_sold/};

    my $response;
    try {
        my $tv = [Time::HiRes::gettimeofday];
        my $contract = produce_contract($short_code, $currency, $is_sold);

        $response = {
            contract_id   => $contract_id,
            underlying    => $contract->underlying->symbol,
            display_name  => $contract->underlying->display_name,
            currency      => $contract->currency,
            longcode      => $contract->longcode,
            shortcode     => $contract->shortcode,
            payout        => $contract->payout,
            contract_type => $contract->code
        };

        my $underlying = BOM::Market::Underlying->new($contract->underlying->symbol);

        #Codes to add CA info
        if ($underlying->market->affected_by_corporate_actions) {

            my $end              = $contract->date_expiry > Date::Utility->new->epoch ? Date::Utility->new->epoch : $contract->date_expiry;
            my $table_info       = {};
            my $corporate_action = $contract->corporate_actions;
            my $ohlc             = $underlying->get_daily_ohlc_table({
                start => $contract->date_start,
                end   => $end
            });
            my $is_double_barrier = $contract->category->two_barriers;

            if ($is_double_barrier) {
                $response->{original_low_barrier}  = $contract->barrier->adjustment->{prev_obj}->as_absolute;
                $response->{original_high_barrier} = $contract->barrier2->adjustment->{prev_obj}->as_absolute;
            } else {
                $response->{original_barrier} = $contract->barrier->adjustment->{prev_obj}->as_absolute;
            }

            if (scalar @{$corporate_action} > 0) {
                foreach my $key (keys $ohlc) {
                    my $action_desc;
                    my $date = Date::Utility->new($ohlc->[$key]->[0])->epoch;
                    foreach my $action (@{$corporate_action}) {
                        if ($date == Date::Utility->new($action->{effective_date})->epoch) {
                            $action_desc = $name_mapper{$action->{type}} . " " . $action->{value} . ":1";
                        }
                    }

                    my $open         = $ohlc->[$key]->[1];
                    my $high         = $ohlc->[$key]->[2];
                    my $low          = $ohlc->[$key]->[3];
                    my $last         = $ohlc->[$key]->[4];
                    my $display_date = Date::Utility->new($ohlc->[$key]->[0])->date_ddmmmyyyy;
                    $table_info->{$display_date} = {
                        date   => $display_date,
                        open   => $open,
                        high   => $high,
                        low    => $low,
                        last   => $last,
                        action => $action_desc,
                    };

                    if ($is_double_barrier) {
                        $response->{adjusted_low_barrier}  = $contract->barrier->as_absolute;
                        $response->{adjusted_high_barrier} = $contract->barrier2->as_absolute;
                    } else {
                        $response->{adjusted_barrier} = $contract->barrier->as_absolute;
                    }

                }
            }

            $response->{is_double_barrier} = $is_double_barrier;
            $response->{ohlc}              = $table_info;
        }
        my $pen = $contract->pricing_engine_name;
        $pen =~ s/::/_/g;
        stats_timing('compute_price.sell.timing', 1000 * Time::HiRes::tv_interval($tv), {tags => ["pricing_engine:$pen"]});

    }
    catch {
        $response = {
            error => {
                message_to_client => BOM::Platform::Context::localize('Sorry, an error occurred while processing your request.'),
                code              => "GetCorporateActionsFailure"
            }};
    };

    return $response;
}

sub get_bid {
    my $params = shift;
    my ($short_code, $contract_id, $currency, $is_sold, $sell_time) = @{$params}{qw/short_code contract_id currency is_sold sell_time/};

    my $response;
    try {
        my $tv = [Time::HiRes::gettimeofday];
        my $contract = produce_contract($short_code, $currency, $is_sold);
        $response = {
            ask_price           => sprintf('%.2f', $contract->ask_price),
            bid_price           => sprintf('%.2f', $contract->bid_price),
            current_spot_time   => $contract->current_tick->epoch,
            contract_id         => $contract_id,
            underlying          => $contract->underlying->symbol,
            display_name        => $contract->underlying->display_name,
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
            contract_type       => $contract->code
        };
        if (not $contract->is_spread) {
            my $contract_affected_by_missing_market_data =
                (not $contract->may_settle_automatically and not @{$contract->corporate_actions} and $contract->missing_market_data) ? 1 : 0;
            if ($contract_affected_by_missing_market_data) {
                $response = BOM::RPC::v3::Utility::create_error({
                        code              => "GetProposalFailure",
                        message_to_client => localize(
                            'There was a market data disruption during the contract period. For real-money accounts we will attempt to correct this and settle the contract properly, otherwise the contract will be cancelled and refunded. Virtual-money contracts will be cancelled and refunded.'
                        )});
                return;
            }
        }

        if (not $contract->is_valid_to_sell and $contract->primary_validation_error) {
            $response->{validation_error} = $contract->primary_validation_error->message_to_client;
        }

        if (not $contract->is_spread) {
            $response->{entry_tick}      = $contract->underlying->pipsized_value($contract->entry_tick->quote) if $contract->entry_tick;
            $response->{entry_tick_time} = $contract->entry_tick->epoch                                        if $contract->entry_tick;
            $response->{exit_tick}       = $contract->underlying->pipsized_value($contract->exit_tick->quote)  if $contract->exit_tick;
            $response->{exit_tick_time}  = $contract->exit_tick->epoch                                         if $contract->exit_tick;
            $response->{current_spot} = $contract->current_spot if $contract->underlying->feed_license eq 'realtime';
            $response->{entry_spot} = $contract->underlying->pipsized_value($contract->entry_spot) if $contract->entry_spot;

            if ($sell_time and my $sell_tick = $contract->underlying->tick_at($sell_time, {allow_inconsistent => 1})) {
                $response->{sell_spot}      = $contract->underlying->pipsized_value($sell_tick->quote);
                $response->{sell_spot_time} = $sell_tick->epoch;
            }

            if ($contract->expiry_type eq 'tick') {
                $response->{tick_count} = $contract->tick_count;
            }

            if ($contract->two_barriers) {
                $response->{high_barrier} = $contract->high_barrier->as_absolute;
                $response->{low_barrier}  = $contract->low_barrier->as_absolute;
            } elsif ($contract->barrier) {
                $response->{barrier} = $contract->barrier->as_absolute;
            }
        }

        my $pen = $contract->pricing_engine_name;
        $pen =~ s/::/_/g;
        stats_timing('compute_price.sell.timing', 1000 * Time::HiRes::tv_interval($tv), {tags => ["pricing_engine:$pen"]});
    }
    catch {
        $response = BOM::RPC::v3::Utility::create_error({
            message_to_client => BOM::Platform::Context::localize('Sorry, an error occurred while processing your request.'),
            code              => "GetProposalFailure"
        });
    };

    return $response;
}

sub send_ask {
    my $params = shift;
    my $args   = $params->{args};

    my $tv = [Time::HiRes::gettimeofday];

    my %details = %{$args};
    my $response;
    try {
        $response = _get_ask(prepare_ask(\%details));
    }
    catch {
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'pricing error',
                message_to_client => BOM::Platform::Locale::error_map()->{'pricing error'}});
    };

    $response->{rpc_time} = 1000 * Time::HiRes::tv_interval($tv);

    return $response;
}

sub get_contract_details {
    my $params = shift;

    my $token_details = BOM::RPC::v3::Utility::get_token_details($params->{token});
    return BOM::RPC::v3::Utility::invalid_token_error() unless ($token_details and exists $token_details->{loginid});

    my $client = BOM::Platform::Client->new({loginid => $token_details->{loginid}});
    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    my $response;
    try {
        my $contract = produce_contract($params->{short_code}, $params->{currency});
        $response = {
            longcode     => $contract->longcode,
            symbol       => $contract->underlying->symbol,
            display_name => $contract->underlying->display_name,
            date_expiry  => $contract->date_expiry->epoch
        };
    }
    catch {
        $response = BOM::RPC::v3::Utility::create_error({
            message_to_client => localize('Sorry, an error occurred while processing your request.'),
            code              => "GetContractDetails"
        });
    };
    return $response;
}

1;
