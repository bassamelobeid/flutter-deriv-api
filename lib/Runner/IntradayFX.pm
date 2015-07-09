package Runner::IntradayFX;

use Moose;

use 5.010;
use strict;
use warnings;

use File::Slurp;
use List::Util qw(sum);

use Date::Utility;
use Format::Util::Numbers qw(roundnear);
use BOM::Market::UnderlyingDB;
use VolSurface::Utils qw(get_strike_for_spot_delta get_delta_for_strike);
use Time::Duration::Concise::Localize;
use BOM::Market::Exchange;
use BOM::Market::Underlying;
use BOM::Market::AggTicks;
use BOM::Product::ContractFactory qw( produce_contract );
use Time::Duration::Concise::Localize;

sub run_dataset {
    my @symbols    = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market            => [qw(forex commodities)],
        contract_category => 'callput',
        expiry_type       => 'intraday',
        start_type        => 'spot',
        submarket         => [qw(major_pairs minor_pairs metals)],
    );

    my @durations  = sort { $a->seconds <=> $b->seconds } map { Time::Duration::Concise::Localize->new(interval => $_) } qw(15m 5h);
    my @bet_types  = qw(ONETOUCH NOTOUCH CALL PUT);
    my $start_date = Date::Utility->new('30-Mar-13 09h45GMT');
    my $exchange   = BOM::Market::Exchange->new('FOREX');

    my $output_file = '/tmp/intraday_benchmark.csv';
    my @header =
        qw(underlying date hour bet_type duration trend vol pips_away_from_spot delta_of_strike tv ask_price delta_adj vega_adj model_markup pnl);
    my $header = join ',', @header;
    write_file($output_file, "$header\n");

    my @results;

    foreach my $symbol (@symbols) {
        my $param = {
            payout   => 10000,
            currency => 'USD',
            backtest => 1,
        };
        print "[$symbol]\n";
        $param->{underlying} = BOM::Market::Underlying->new({
            symbol   => $symbol,
            for_date => $start_date,
        });

        my $at = BOM::Market::AggTicks->new();
        $at->flush($symbol);

        $at->fill_from_historical_feed({
            underlying   => $param->{underlying},
            ending_epoch => $start_date->epoch,
            interval     => $durations[-1],
        });

        foreach my $duration (@durations) {
            $param->{duration}     = $duration->as_concise_string;
            $param->{date_start}   = $start_date;
            $param->{date_pricing} = $start_date;

            my %pips = (0 => 1);
            my $i = 1;
            while ($i <= 8) {
                my $underlying = $param->{underlying};
                my $move       = $underlying->pipsized_value(
                    $underlying->spot - get_strike_for_spot_delta({
                            delta            => ($i * 10) / 100,
                            option_type      => 'VANILLA_CALL',
                            atm_vol          => 0.10,
                            t                => $duration->days / 365,
                            r_rate           => 0,
                            q_rate           => 0,
                            spot             => $underlying->spot,
                            premium_adjusted => $underlying->market_convention->{delta_premium_adjusted},
                        })
                    ) /
                    $underlying->pip_size;
                $pips{$move + 0} = 1;
                $i += 1;
            }
            foreach my $pip_move (sort { $a <=> $b } keys %pips) {
                $param->{barrier}  = 'S' . $pip_move . 'P';
                $param->{pip_move} = $pip_move;
                foreach my $bet_type (@bet_types) {
                    next if not $param->{barrier};
                    next if ($param->{barrier} eq 'S0P' and $bet_type =~ /TOUCH/);
                    $param->{bet_type} = $bet_type;

                    my $reconsidered = produce_contract($param);
                    # We don't need the adjustment in benchmark test.
                    # This avoid having false positive price changes.
                    $reconsidered->ask_probability->exclude_adjustment('intraday_historical_iv_risk');

                    eval {
                        die if ($reconsidered->pricing_engine_name !~ /IntradayHist/);
                        my $buy_price  = roundnear(1, $reconsidered->ask_price);
                        my $ask        = $reconsidered->ask_probability;
                        my $used_delta = roundnear(
                            1,
                            1e4 * get_delta_for_strike({
                                    strike           => $reconsidered->barrier->as_absolute,
                                    atm_vol          => $reconsidered->pricing_args->{iv},
                                    spot             => $reconsidered->current_spot,
                                    t                => $reconsidered->timeinyears->amount,
                                    r_rate           => 0,
                                    q_rate           => 0,
                                    premium_adjusted => $reconsidered->underlying->market_convention->{delta_premium_adjusted},
                                }));

                        die if ($used_delta < 1500 or $used_delta > 8500);
                        my $dp = $param->{date_pricing};
                        delete $param->{date_pricing};
                        my $final_value = roundnear(1, produce_contract($param)->ask_price);
                        $param->{date_pricing} = $dp;

                        my %entry = (
                            underlying => $reconsidered->underlying->symbol,
                            date       => $reconsidered->date_start->date_ddmmmyy,
                            hour       => $reconsidered->date_start->hour,
                            bet_type   => $reconsidered->bet_type->code,
                            duration   => $reconsidered->remainig_time->minutes,
                            trend      => int(
                                roundnear(
                                    1,
                                    $ask->peek_amount('intraday_trend') /
                                        $ask->peek_amount('period_opening_value') * 100000 /
                                        sqrt($reconsidered->remaining_time->minutes)
                                ) / 5
                            ),
                            vol                 => roundnear(1, $reconsidered->pricing_args->{iv} * 100),
                            pips_away_from_spot => $param->{pip_move},
                            delta_of_strike     => $used_delta,
                            tv                  => roundnear(1, $reconsidered->theo_price),
                            ask_price           => $buy_price,
                            delta_adj           => roundnear(1, $ask->peek_amount('delta_correction') * 1e4),
                            vega_adj            => roundnear(1, $ask->peek_amount('vega_correction') * 1e4),
                            model_markup        => roundnear(1, $ask->peek_amount('model_markup') * 1e4),
                            pnl                 => $final_value - $buy_price,
                        );
                        push @results, \%entry;
                        my @result = map { $entry{$_} } @header;
                        my $line = join ',', @result;
                        append_file($output_file, "$line\n");
                    };
                }
            }
        }
    }

    my $analysis;

    foreach my $result (@results) {
        my $bet_type = $result->{bet_type};
        my $pnl      = $result->{pnl};
        push @{$analysis->{$bet_type}}, $pnl;
    }

    my $aggregated_results;
    foreach my $bet_type (keys %$analysis) {
        my @pnls        = @{$analysis->{$bet_type}};
        my $num_of_data = scalar(@pnls);
        my $pnl_sum     = sum(@pnls);
        $aggregated_results->{$bet_type} = $pnl_sum / $num_of_data;
    }

    return $aggregated_results;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
