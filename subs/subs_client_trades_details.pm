use strict;
use warnings;

use Moose;
use Try::Tiny;

use Date::Utility;
use BOM::Platform::Data::Persistence::DB::Relationships;
use BOM::Platform::Model::FinancialMarketBet::Factory;
use Math::Util::CalculatedValue::Validatable;
use BOM::Platform::Data::Persistence::ConnectionBuilder;
use BOM::Market::PricingInputs::VolSurface::Helper::Converter qw( get_delta_for_strike );
use BOM::Market::PricingInputs::Volatility::Display;

has 'db' => (
    is      => 'rw',
    isa     => 'Maybe[Rose::DB]',
    default => sub {
        return BOM::Platform::Data::Persistence::ConnectionBuilder->new({broker_code => 'FOG'})->db;
    },
);


sub get_trades_details {
    my ($self) = @_;

    $self->client->db($self->db);

    my (@output, $hdrs);

    foreach my $account ($self->client->account) {

        my %trx_args = (
            query => [
                action_type      => 'buy',
                transaction_time => {ge_le => [$self->start_date->db_timestamp, $self->end_date->db_timestamp]},
            ],
            sort_by => 'transaction_time, id',
        );

        my $trx_count = $account->transaction_count(%trx_args);
        print STDERR "for $account will process $trx_count buy-transactions..";

        my $trx_iter = $account->transaction_iterator(%trx_args);
        my $trx_i    = 0;
        while (my $transaction = $trx_iter->next and ++$trx_i) {
            printf STDERR "processing trxn $trx_i of $trx_count: $transaction..\n" if $trx_i % 10 == 0;

            my $results = $self->_build_nonrunbet_entry($transaction);
            push @output, $results;
            $hdrs->{$_} = 1 for keys %$results;

        }
    }

    return $hdrs, @output;
}

sub _exchange_rate {
    my ($self, $currency_code) = @_;
    return 1 if $currency_code eq 'USD';
    # make sure we look up each currency just once, to ensure consistent rates for the whole report.
    $self->{_spot}{$currency_code} ||= BOM::Market::Underlying->new("frx${currency_code}USD")->spot;
    return $self->{_spot}{$currency_code};
}

=head2 _build_nonrunbet_entry

Returns an array reference of client's trade details

=cut

sub _build_nonrunbet_entry {
    my ($self, $transaction) = @_;

    my $currency         = $transaction->account->currency_code;
    my $exchange_rate    = $self->_exchange_rate($currency);
    my $fmb              = $transaction->financial_market_bet;
    my $real_fmb         = BOM::Platform::Model::FinancialMarketBet::Factory->get(financial_market_bet_record => $fmb);
    my $orig             = produce_contract($real_fmb, $currency);
    my $sell_transaction = $fmb->find_transaction([action_type => 'sell'])->[0];
    my $bet              = make_similar_contract($orig, {price_at => 'start'});

    my $client_param = _get_client_input_parameter({
            bet           => $bet,
            transaction   => $transaction,
            exchange_rate => $exchange_rate,
    });
    my $times = _get_time_parameter($transaction);

    my $bet_prob = _get_prob_parameter({
            bet         => $bet,
            transaction => $transaction,
    });

    my $client_pnl = _get_client_pnl({
            bet           => $bet,
            transaction   => $transaction,
            exchange_rate => $exchange_rate,
    });

    my $trend = _get_trend($transaction);

    my $greeks_buy  = _get_greeks($transaction,      'buy');
    my $greeks_sell = _get_greeks($sell_transaction, 'sell');

    my $vols = _get_vol({
            bet         => $bet,
            transaction => $transaction,
    });

    return {
        param_bet_ref                    => $transaction->id,
        param_bet_type                   => $client_param->{'bet_type'},
        param_duration_days              => $client_param->{'duration_days'},
        param_duration_minutes           => $client_param->{'duration_minutes'},
        param_strike_high                => $client_param->{'strike_high'},
        param_strike_low                 => $client_param->{'strike_low'},
        param_strike_low_delta           => $client_param->{'strike_low_delta'},
        param_strike_high_delta          => $client_param->{'strike_high_delta'},
        param_payout                     => $client_param->{'payout'},
        param_payout_USD                 => $client_param->{'payout_USD'},
        param_payout_currency            => $client_param->{'currency'},
        param_purchase_price             => $client_param->{'purchase_price'},
        param_purchase_price_USD         => $client_param->{'purchase_price_USD'},
        param_sell_price                 => $client_param->{'sell_price'},
        param_sell_price_USD             => $client_param->{'sell_price_USD'},
        param_underlying                 => $client_param->{'underlying'},
        param_underlying_market          => $client_param->{'market'},
        param_start_time_type            => $client_param->{'start_time_type'},
        Time_buy                         => $times->{'buy'},
        Time_start                       => $times->{'start'},
        Time_expiry                      => $times->{'expiry'},
        Time_sell                        => $times->{'sell'},
        Time_buy_hour                    => $times->{'buy_hour'},
        Time_sell_hour                   => $times->{'sell_hour'},
        Time_sold_before_expiry          => $times->{'sold_before_expiry'},
        prob_ask                         => $bet_prob->{'prob_ask'},
        prob_bid                         => $bet_prob->{'prob_bid'},
        prob_at_sale                     => $bet_prob->{'prob_at_sale'},
        prob_at_expiry                   => $bet_prob->{'prob_at_expiry'},
        prob_BS                          => $bet_prob->{'prob_BS'},
        prob_theo                        => $bet_prob->{'prob_theo'},
        prob_markup                      => $bet_prob->{'markup'},
        prob_survival                    => $bet_prob->{'prob_survival'},
        price_news_factor                => $bet_prob->{'news_factor'},
        pricing_engine_name              => $bet_prob->{'pricing_engine_name'},
        pnl_client                       => $client_pnl->{'pnl_client'},
        pnl_client_if_held_to_expiry     => $client_pnl->{'pnl_client_if_held_to_expiry'},
        pnl_client_USD                   => $client_pnl->{'pnl_client_USD'},
        pnl_client_if_held_to_expiry_USD => $client_pnl->{'pnl_client_if_held_to_expiry_USD'},
        trend_start_to_sale              => $trend->{'trend_start_to_sale'},
        trend_start_to_expiry            => $trend->{'trend_start_to_expiry'},
        vol_iv                           => $vols->{'iv'},
        vol_skew                         => $vols->{'skew'},
        vol_kurtosis                     => $vols->{'kurtosis'},
        ticks                            => '',
        forecast                         => '',
        game_time                        => '',
        %$greeks_buy,
        %$greeks_sell,
    };
}

=head2 _get_client_input_parameter

Returns a hash which contains all those parameters which are predefined by client for a particular contract

=cut

sub _get_client_input_parameter {
    my $args          = shift;
    my $bet           = $args->{'bet'};
    my $transaction   = $args->{'transaction'};
    my $exchange_rate = $args->{'exchange_rate'};
    my $params;
    my $barriers = _get_barrier_details($bet);

    $params->{'bet_type'}           = $bet->bet_type->code;
    $params->{'duration_days'}      = $bet->get_time_to_expiry({from => $bet->date_start})->days;
    $params->{'duration_minutes'}   = $bet->get_time_to_expiry({from => $bet->date_start})->minutes;
    $params->{'strike_high'}        = $barriers->{'strike_high'};
    $params->{'strike_low'}         = $barriers->{'strike_low'};
    $params->{'strike_low_delta'}   = $barriers->{'delta_strike_low'};
    $params->{'strike_high_delta'}  = $barriers->{'delta_strike_high'};
    $params->{'payout'}             = $transaction->financial_market_bet->payout_price;
    $params->{'payout_USD'}         = $params->{'payout'} * $exchange_rate;
    $params->{'purchase_price'}     = $transaction->financial_market_bet->buy_price;
    $params->{'purchase_price_USD'} = $params->{'purchase_price'} * $exchange_rate;
    $params->{'sell_price'}         = $transaction->financial_market_bet->sell_price;
    $params->{'sell_price_USD'}     = $params->{'sell_price'} * $exchange_rate;
    $params->{'currency'}           = $bet->currency;
    $params->{'underlying'}         = $bet->underlying->symbol;
    $params->{'market'}             = $bet->market->name;
    $params->{'start_time_type'}    = $bet->is_forward_starting ? 'forward_starting' : 'now';

    return $params;

}

=head2 _get_time_parameter

Returns a hash which contains all time related details for a particular contract

=cut

sub _get_time_parameter {
    my $buy_transaction = shift;

    my $fmb = $buy_transaction->financial_market_bet;
    my $sell_transaction = $fmb->find_transaction([action_type => 'sell'])->[0];

    my $time;
    my $buy = Date::Utility->new($fmb->purchase_time);
    $time->{buy}      = $buy->datetime_yyyymmdd_hhmmss;
    $time->{buy_hour} = $buy->hour;
    $time->{start}    = Date::Utility->new($fmb->start_time)->datetime_yyyymmdd_hhmmss if $fmb->start_time;
    $time->{expiry}   = Date::Utility->new($fmb->expiry_time)->datetime_yyyymmdd_hhmmss if $fmb->expiry_time;
    if ($sell_transaction) {
        my $sell = Date::Utility->new($sell_transaction->transaction_time);
        $time->{sell}      = $sell->datetime_yyyymmdd_hhmmss;
        $time->{sell_hour} = $sell->hour;
        if ($fmb->expiry_time and $sell_transaction->transaction_time < $fmb->expiry_time) {
            $time->{sold_before_expiry} = 1;
        }
    }

    return $time;

}

=head2 _get_barrier_details

Returns a hash which contains all barriers related details for a particular contract

=cut

sub _get_barrier_details {
    my $bet = shift;
    my $barriers;

    # To get strike and delta for strike

    $barriers->{'strike_high'} = ($bet->barrier) ? $bet->barrier->as_absolute : '';
    $barriers->{'strike_low'} = ($bet->bet_type->two_barriers) ? $bet->barrier2->as_absolute : '';

    try {
        my $atm_vol = $bet->volsurface->get_volatility({
                delta => 50,
                days  => $bet->timeinyears->amount * 365,
        });

        $barriers->{'delta_strike_high'} = 100 * get_delta_for_strike({
                strike           => $bet->barrier->as_absolute,
                atm_vol          => $atm_vol,
                t                => $bet->timeinyears->amount,
                spot             => $bet->current_spot,
                r_rate           => $bet->r_rate,
                q_rate           => $bet->q_rate,
                premium_adjusted => $bet->underlying->{market_convention}->{delta_premium_adjusted},
        });

        if ($bet->bet_type->two_barriers) {

            $barriers->{'delta_strike_low'} = 100 * get_delta_for_strike({
                    strike           => $bet->barrier2->as_absolute,
                    atm_vol          => $atm_vol,
                    t                => $bet->timeinyears->amount,
                    spot             => $bet->current_spot,
                    r_rate           => $bet->r_rate,
                    q_rate           => $bet->q_rate,
                    premium_adjusted => $bet->underlying->{market_convention}->{delta_premium_adjusted},
            });
        } else {
            $barriers->{'delta_strike_low'} = '';
        }

    }
    catch {
        $barriers->{'delta_strike_high'} = '';
        $barriers->{'delta_strike_low'}  = '';
    };

    return $barriers;

}

=head2 _get_prob_parameter

Returns a hash which contains all probability related details for a particular contract

=cut

sub _get_prob_parameter {
    my $args        = shift;
    my $bet         = $args->{bet};
    my $transaction = $args->{transaction};
    my $fmb         = $transaction->financial_market_bet;
    my $qbv         = $transaction->quants_bet_variables;
    my $payout      = $fmb->payout_price;
    my $sell_price  = $fmb->sell_price;
    my $prob        = {};

    $prob->{prob_at_sale} = $sell_price / $payout if $payout && defined($sell_price);
    $prob->{news_factor} = $qbv->news_fct if $qbv;

    try {
        $prob->{prob_ask}  = $bet->ask_probability->amount;
        $prob->{prob_bid}  = $bet->bid_probability->amount;
        $prob->{prob_BS}   = $bet->bs_probability->amount;
        $prob->{prob_theo} = $bet->theo_probability->amount;
        $prob->{markup}    = $bet->total_markup->amount;

        $prob->{pricing_engine_name} = $bet->pricing_engine_name;
        if ($prob->{pricing_engine_name} =~ /VannaVolga/) {
            $prob->{prob_survival} = $bet->pricing_engine_name->new({bet => $bet})->survival_weight->{survival_probability};
        }

        if ($payout and my $reconsidered = make_similar_contract($bet, {priced_at => 'now'})) {
            $prob->{'prob_at_expiry'} = ($reconsidered->is_expired) ? $reconsidered->value / $payout : '';
        }
    }
    catch {
        if ($payout) {
            $prob->{prob_ask} = $fmb->buy_price / $payout;
            $prob->{prob_theo} = $qbv->theo / $payout if $qbv;
        }
    };

    return $prob;
}

=head2 _get_client_pnl

Returns a hash which contains all client's pnl details for a particular contract

=cut

sub _get_client_pnl {
    my $args          = shift;
    my $bet           = $args->{'bet'};
    my $transaction   = $args->{'transaction'};
    my $exchange_rate = $args->{'exchange_rate'};

    my $client_pnl;

    my $sell_price = $transaction->financial_market_bet->sell_price;
    my $buy_price  = $transaction->financial_market_bet->buy_price;
    if (defined($sell_price) && defined($buy_price)) {
        $client_pnl->{'pnl_client'}     = $sell_price - $buy_price;
        $client_pnl->{'pnl_client_USD'} = $client_pnl->{'pnl_client'} * $exchange_rate;
    }

    try {
        my $reconsidered = make_similar_contract($bet, {priced_at => 'now'});

        if ($reconsidered->is_expired) {
            $client_pnl->{'pnl_client_if_held_to_expiry'}     = $reconsidered->value - $transaction->financial_market_bet->buy_price;
            $client_pnl->{'pnl_client_if_held_to_expiry_USD'} = $client_pnl->{'pnl_client_if_held_to_expiry'} * $exchange_rate;
        } else {
            $client_pnl->{'pnl_client_if_held_to_expiry'}     = '';
            $client_pnl->{'pnl_client_if_held_to_expiry_USD'} = '';
        }
    }
    catch {
        $client_pnl->{'pnl_client_if_held_to_expiry'}     = '';
        $client_pnl->{'pnl_client_if_held_to_expiry_USD'} = '';
    };

    return $client_pnl;
}

=head2 _get_trend

Returns a hash which contains all trends details for a particular contract

=cut

sub _get_trend {
    my $buy_transaction = shift;

    my $trend      = {};
    my $fmb        = $buy_transaction->financial_market_bet;
    my $underlying = BOM::Market::Underlying->new($fmb->underlying_symbol);
    my $buy_time   = Date::Utility->new($fmb->purchase_time);

    # single-loop {}s here allow use of 'last' to jump over missing data problems
    {
        my $buy_tick = $underlying->tick_at($buy_time->epoch, {allow_inconsistent => 1}) || last;
        my $buy_quote = $buy_tick->quote || last;
        {
            my $sell_transaction = $fmb->find_transaction([action_type => 'sell'])->[0] || last;
            my $sell_time        = Date::Utility->new($sell_transaction->transaction_time);
            my $sell_tick        = $underlying->tick_at($sell_time->epoch, {allow_inconsistent => 1}) || last;
            my $sell_quote       = $sell_tick->quote || last;
            $trend->{trend_start_to_sale} = log($sell_quote / $buy_quote) * 100;
        }
        {
            my $expiry_time = Date::Utility->new($fmb->expiry_time) || last;
            $expiry_time->epoch < Date::Utility->new->epoch || last;
            my $expiry_tick = $underlying->tick_at($expiry_time->epoch, {allow_inconsistent => 1}) || last;
            my $expiry_quote = $expiry_tick && $expiry_tick->quote || last;
            $trend->{trend_start_to_expiry} = log($expiry_quote / $buy_quote) * 100;
        }
    }
    return $trend;
}

=head2 _get_greeks

Returns a hash which contains all greeks details for a particular contract

=cut

sub _get_greeks {
    my $transaction = shift || return {};
    my $side        = shift;
    my $greeks      = {};

    my $qbv = $transaction->quants_bet_variables || return {};
    my $fld = 0;
    for my $col (qw/theo trade recalc iv win delta theta vega gamma div int spot/) {
        my $key = sprintf 'qbv_%s_%02d_%s', $side, ++$fld, $col;
        $greeks->{$key} = $qbv->$col;
    }

    return $greeks;

}

=head2 _get_vol

Returns a hash which contains all volatility details for a particular contract

=cut

sub _get_vol {
    my $args        = shift;
    my $bet         = $args->{'bet'};
    my $transaction = $args->{'transaction'};
    my $time        = Date::Utility->new($transaction->financial_market_bet->purchase_time)->epoch;
    my $vols;
    try {
        my $volsurface = $bet->volsurface;

        my $days = $bet->timeindays->amount;
        my $d = BOM::Market::PricingInputs::Volatility::Display->new(surface => $volsurface);

        my $smile = $volsurface->surface->{$days}->{smile};

        my $rr_bf = $volsurface->get_rr_bf_for_smile($smile);
        my $skew  = $d->get_skew_kurtosis($rr_bf);

        $vols->{'iv'}       = $bet->pricing_iv;
        $vols->{'skew'}     = $skew->{'skew'};
        $vols->{'kurtosis'} = $skew->{'kurtosis'};
    }
    catch {
        $vols->{'iv'}       = $transaction->quants_bet_variables->iv;
        $vols->{'skew'}     = '';
        $vols->{'kurtosis'} = '';
    };

    return $vols;
}

1;
