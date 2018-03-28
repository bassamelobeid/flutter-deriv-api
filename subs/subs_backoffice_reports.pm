## no critic (RequireExplicitPackage)
use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use Date::Manip;
use JSON::MaybeXS;
use List::Util qw( min max );
use Cache::RedisDB;
use Format::Util::Numbers qw/roundcommon financialrounding/;

use LandingCompany::Registry;
use Postgres::FeedDB::CurrencyConverter qw(in_USD);
use BOM::RiskReporting::Dashboard;
use BOM::Platform::Runtime;
use List::MoreUtils qw(uniq);
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Product::Contract::PredefinedParameters;

sub DailyTurnOverReport {
    my ($args, $options) = @_;

    if ($args->{month} !~ /^\w{3}-\d{2}$/) {
        code_exit_BO("<p>Invalid month $args->{month}</p>");
    }

    my $initial_note   = '(BUY-SELL represents the company profit)';
    my @all_currencies = LandingCompany::Registry->new()->all_currencies;
    my %rates          = map { $_ => in_USD(1, $_) } grep { $_ !~ /^(?:ETC|BCH)$/ } @all_currencies;

    my %template = (
        initial_note => $initial_note,
        risk_report  => request()->url_for("backoffice/quant/risk_dashboard.cgi"),
        currencies   => \@all_currencies,
        rates        => \%rates,
        buy_label    => 'BUY',
        sell_label   => 'SELL',
        days         => [],
    );

    my $action_bb = 'buy';
    my $action_ss = 'sell';
    my ($lastaggbets, $allprevaggbets);

    my $now         = Date::Utility->new;
    my $month_to_do = $args->{month};
    my $this_month  = ($now->date_ddmmmyy =~ /$month_to_do/) ? 1 : 0;    # A rather inelegant way to see if we are doing this month.

    my $currdate = Date::Utility->new('1-' . $args->{'month'});

    my (%allbuys, %allsells);
    my ($allUSDsells, $allUSDbuys, $allpl);

    # get latest timestamp in redis cache
    my $cache_prefix = 'DAILY_TURNOVER';
    # TODO: we should rename the method `keys` of Cache::RedisDB, otherwise perlcritic will report DeprecatedFeatures error
    my $redis_time = Cache::RedisDB->keys($cache_prefix);                ## no critic (DeprecatedFeatures)

    my $latest_time;
    foreach my $time (@{$redis_time}) {
        my $bom_date = Date::Utility->new($time);
        if ($bom_date->month == $currdate->month) {
            if (not $latest_time) {
                $latest_time = $bom_date;
                next;
            }

            if ($bom_date->epoch > $latest_time->epoch) {
                $latest_time = $bom_date;
            }
        }
    }

    code_exit_BO('No TurnOver data in redis yet') unless $latest_time;

    # get latest cache
    my $cache_query = Cache::RedisDB->get($cache_prefix, $latest_time->db_timestamp);
    $cache_query = JSON::MaybeXS->new->decode($cache_query);

    my $aggregate_transactions = $cache_query->{agg_txn};
    my $active_clients         = $cache_query->{active_clients};
    my $eod_market_values      = $cache_query->{eod_open_bets_value};

    # get end of previous month open bets value
    my $prevaggbets = int($eod_market_values->{$currdate->epoch - 86400}->{market_value} // 0);
    my $firstaggbets = $prevaggbets;

    my $days_in_month = $currdate->days_in_month;
    foreach my $day (1 .. $days_in_month) {

        my $date = $day . '-' . $args->{'month'};
        my $when = Date::Utility->new($date);

        my %tday = (
            is_weekend => $when->is_a_weekend,
            date       => $date,
        );

        my ($USDbuys, $USDsells);

        foreach my $curr (@all_currencies) {
            my $rate = $rates{$curr} // 0;

            my $buys = $aggregate_transactions->{$when->date_yyyymmdd}->{$action_bb}->{$curr}->{'amount'} // 0;
            $USDbuys += $buys * $rate;
            $allbuys{$curr} += $buys;

            my $sells = $aggregate_transactions->{$when->date_yyyymmdd}->{$action_ss}->{$curr}->{'amount'} // 0;
            $USDsells += $sells * $rate;
            $allsells{$curr} += $sells;

            $tday{buys}->{$curr}  = int $buys;
            $tday{sells}->{$curr} = int $sells;
        }

        $USDbuys  = roundcommon(0.01, $USDbuys);
        $USDsells = roundcommon(0.01, $USDsells);
        $tday{USD_buys}  = int $USDbuys;
        $tday{USD_sells} = int $USDsells;

        my $pl = roundcommon(0.01, $USDbuys - $USDsells);
        $tday{pl} = int $pl;

        # aggregate outstanding bets
        my $aggbets = int($eod_market_values->{$when->epoch}->{market_value} // 0);
        $tday{agg_bets} = $aggbets;

        if ($aggbets and ($USDbuys > 1 or $USDsells > 1)) {
            $lastaggbets = $aggbets;
        } else {
            $lastaggbets = 0;
        }

        my $plbets = 0;
        if ($when->epoch <= ($now->epoch - $now->seconds_after_midnight)) {
            $plbets = $prevaggbets - $aggbets;
        }
        $allprevaggbets += $plbets;
        $tday{pl_bets} = $plbets;

        # p/l on day
        my $plonday = 0;
        if ($aggbets and $USDbuys) {
            $plonday = ($prevaggbets) ? $prevaggbets - $aggbets + $pl : $pl;
        }
        $tday{pl_on_day} = int $plonday;

        $tday{active_clients} = $active_clients->{$when->epoch}->{active_clients};

        $prevaggbets = $aggbets;
        $allUSDbuys  += $USDbuys;
        $allUSDsells += $USDsells;
        $allpl       += $pl;

        push @{$template{days}}, \%tday;
    }

    foreach my $curr (@all_currencies) {
        $allbuys{$curr}  = int financialrounding('amount', $curr, $allbuys{$curr});
        $allsells{$curr} = int financialrounding('amount', $curr, $allsells{$curr});
    }

    $template{mtm_calc_time} = $latest_time->db_timestamp;
    $template{all_buys}      = \%allbuys;
    $template{all_sells}     = \%allsells;
    $template{all_USD_buys}  = int $allUSDbuys;
    $template{all_USD_sells} = int $allUSDsells;
    $template{all_pl}        = int $allpl;
    my $aggbetsdiff = $firstaggbets - $lastaggbets;
    $template{agg_bets_diff}     = int $aggbetsdiff;
    $template{all_prev_agg_bets} = $allprevaggbets;

    my $start_of_month   = Date::Utility->new('1-' . $month_to_do);
    my $end_of_month     = $start_of_month->plus_time_interval($days_in_month . 'd')->minus_time_interval('1s');
    my $month_completed  = min(1, max(1e-5, ($latest_time->epoch - $start_of_month->epoch) / ($end_of_month->epoch - $start_of_month->epoch)));
    my $projection_ratio = 1 / $month_completed;

    $template{summarize_turnover} = 1;
    my $estimated_pl = int($allpl + $aggbetsdiff);
    $template{estimated_pl}        = $estimated_pl;
    $template{pct_month_completed} = roundcommon(0.01, 100 * $month_completed);
    $template{pct_hold}            = roundcommon(0.01, 100 * ($estimated_pl / ($allUSDbuys || 1)));
    $template{projected_pl}        = int($estimated_pl * $projection_ratio);
    $template{projected_turnover}  = int($allUSDbuys * $projection_ratio);

    return %template;
}

sub MultiBarrierReport {
    my $self      = shift;
    my @open_bets = @{BOM::RiskReporting::Dashboard->new->_open_bets_at_end};
    my $multibarrier;
    my $symbol;
    foreach my $open_contract (@open_bets) {
        my $contract = produce_contract($open_contract->{short_code}, $open_contract->{currency_code});
        next if not $contract->can("trading_period_start");
        next if not $contract->is_intraday;

        my @available_barrier = @{$contract->predefined_contracts->{available_barriers}};

        # Rearrange the index of the barrier from  the median of the barrier list (ie the ATM barrier)
        my %reindex_barrier_list = map { $available_barrier[$_] => $_ - (int @available_barrier / 2) } (0 .. $#available_barrier);
        my $barrier_index        = $reindex_barrier_list{$contract->barrier->as_absolute};
        my $spot                 = $contract->current_spot;
        my ($closest_barrier_to_spot) =
            map { $_->{barrier} } sort { $a->{diff} <=> $b->{diff} } map { {barrier => $_, diff => abs($spot - $_)} } @available_barrier;
        my $spot_index           = $reindex_barrier_list{$closest_barrier_to_spot};
        my $trading_period_start = Date::Utility->new($contract->trading_period_start)->datetime;
        warn "tradinhg windlow"
            . $trading_period_start . '_'
            . $contract->date_expiry->datetime
            . " underlying "
            . $contract->underlying->symbol
            . " spot $spot spot index [$spot_index]\n";
        $multibarrier->{$trading_period_start . '_' . $contract->date_expiry->datetime}->{$contract->bet_type}->{barrier}->{$barrier_index}
            ->{$contract->underlying->symbol} +=
            financialrounding('price', 'USD', in_USD($open_contract->{buy_price}, $open_contract->{currency_code}));
        push @{$symbol->{$trading_period_start . '_' . $contract->date_expiry->datetime}}, $contract->underlying->symbol;

        $multibarrier->{$trading_period_start . '_' . $contract->date_expiry->datetime}->{spot}->{$contract->underlying->symbol} = $spot_index;
    }
    my $final;
    foreach my $expiry (sort keys %{$multibarrier}) {
        my $max = 0;

        for (-3 ... 3) {
            $final->{$expiry}->{PUT}->{barrier}->{$_}   = {};
            $final->{$expiry}->{CALLE}->{barrier}->{$_} = {};
            foreach my $symbol (uniq @{$symbol->{$expiry}}) {
                my $CALL = $multibarrier->{$expiry}->{CALLE}->{barrier}->{$_}->{$symbol} // 0;
                my $PUT  = $multibarrier->{$expiry}->{PUT}->{barrier}->{$_}->{$symbol}   // 0;
                $final->{$expiry}->{CALLE}->{barrier}->{$_}->{$symbol}->{'isSpot'} = 1
                    if defined $multibarrier->{$expiry}->{spot}->{$symbol} && $multibarrier->{$expiry}->{spot}->{$symbol} == $_;
                $final->{$expiry}->{PUT}->{barrier}->{$_}->{$symbol}->{'isSpot'} = 1
                    if defined $multibarrier->{$expiry}->{spot}->{$symbol} && $multibarrier->{$expiry}->{spot}->{$symbol} == $_;
                if ($CALL > 0 or $PUT > 0) {
                    if ($CALL > $PUT) {
                        $final->{$expiry}->{CALLE}->{barrier}->{$_}->{$symbol}->{value} = $CALL - $PUT;
                        $final->{$expiry}->{PUT}->{barrier}->{$_}->{$symbol}->{value}   = 0;
                        $max = ($CALL - $PUT) > $max ? $CALL - $PUT : $max;
                    } else {
                        $final->{$expiry}->{PUT}->{barrier}->{$_}->{$symbol}->{value}   = $PUT - $CALL;
                        $final->{$expiry}->{CALLE}->{barrier}->{$_}->{$symbol}->{value} = 0;
                        $max = ($PUT - $CALL) > $max ? $PUT - $CALL : $max;
                    }
                }
            }
        }
        $final->{$expiry}->{max} = $max;
    }
    return $final;
}

1;
