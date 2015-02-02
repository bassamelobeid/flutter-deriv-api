use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use Date::Manip;
use JSON qw(from_json to_json);
use List::Util qw( min max );

use Cache::RedisDB;
use BOM::Utility::Format::Numbers qw(virgule roundnear);
use BOM::Platform::Data::Persistence::DataMapper::CollectorReporting;
use BOM::Platform::Data::Persistence::DataMapper::HistoricalMarkedToMarket;
use BOM::Platform::Runtime;
use BOM::Utility::CurrencyConverter qw(in_USD);


sub DailyTurnOverReport {
    my ($args, $options) = @_;


    if ($args->{month} !~ /^\w{3}-\d{2}$/) {
        print "<p>Invalid month $args->{month}</p>";
        code_exit_BO();
    }

    my $mtm_calc_time = $report_mapper->get_last_generated_historical_marked_to_market_time();
    my $initial_note = '(BUY-SELL represents the company profit)';
    my @all_currencies = BOM::Platform::Runtime->instance->landing_companies->all_currencies;
    my %rates = map { $_ => in_USD(1, $_) } @all_currencies;

    my %template = (
        mtm_calc_time => $mtm_calc_time,
        initial_note  => $initial_note,
        risk_report   => request()->url_for("backoffice/quant/risk_dashboard.cgi"),
        currencies    => \@all_currencies,
        rates         => \%rates,
        buy_label     => 'BUY',
        sell_label    => 'SELL',
        days          => [],
    );

    my $action_bb = 'buy';
    my $action_ss = 'sell';
    my ($lastaggbets, $allprevaggbets);

    my $now         = BOM::Utility::Date->new;
    my $month_to_do = $args->{month};
    my $this_month  = ($now->date_ddmmmyy =~ /$month_to_do/) ? 1 : 0;    # A rather inelegant way to see if we are doing this month.

    my $currdate = BOM::Utility::Date->new('1-' . $args->{'month'});
    my $prevdate = BOM::Utility::Date->new($currdate->epoch - 86400)->date_ddmmmyy;

    my (%allbuys, %allsells);
    my ($allUSDsells, $allUSDbuys, $allpl);

    # get latest timestamp in redis cache
    my $redis_time = Cache::RedisDB->keys($cache_prefix);
    my $latest_time;
    foreach my $time (@{$redis_time}) {
        my $bom_date = BOM::Utility::Date->new($time);
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

    # get latest cache
    my $cache_qeury = Cache::RedisDB->get($cache_prefix, $latest_time->db_timestamp);
    $cache_query = from_json($cache_query);

    my $aggregate_transactions = $cache_query->{agg_txn};
    my $active_clients = $cache_query->{active_clients};
    my $eod_market_values = $cache_query->{eod_open_bets_value};

    # get end of previous month open bets value
    my $prevaggbets = int($eod_market_values->{$prevdate->epoch}->{market_value});
    my $firstaggbets = $prevaggbets;

    my $days_in_month  = $currdate->days_in_month;
    foreach my $day (1 .. $days_in_month) {

        my $date = $day . '-' . $args->{'month'};
        my $when = BOM::Utility::Date->new($date);

        my %tday = (
            is_weekend => $when->is_a_weekend,
            date       => $date,
        );

        my ($USDbuys, $USDsells);

        foreach my $curr (@all_currencies) {
            my $rate = $rates{$curr};

            my $b = $aggregate_transactions->{$when->date_yyyymmdd}->{$action_bb}->{$curr}->{'amount'};
            my $buys        += $b;
            $USDbuys        += $b * $rate;
            $allbuys{$curr} += $b;

            my $s = $aggregate_transactions->{$when->date_yyyymmdd}->{$action_ss}->{$curr}->{'amount'};
            my $sells        += $s;
            $USDsells        += $s * $rate;
            $allsells{$curr} += $s;

            $tday{buys}->{$curr}  = int $buys;
            $tday{sells}->{$curr} = int $sells;
        }

        $USDbuys  = roundnear(0.01, $USDbuys);
        $USDsells = roundnear(0.01, $USDsells);
        $tday{USD_buys}  = int $USDbuys;
        $tday{USD_sells} = int $USDsells;

        my $pl = roundnear(0.01, $USDbuys - $USDsells);
        $tday{pl} = int $pl;

        # aggregate outstanding bets
        my $aggbets = int($eod_market_values->{$when->epoch}->{market_value});
        $tday{agg_bets} = $aggbets;

        if ($aggbets and ($USDbuys > 1 or $USDsells > 1)) {
            $lastaggbets = $aggbets;
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
        $allbuys{$curr}  = int roundnear(0.01, $allbuys{$curr});
        $allsells{$curr} = int roundnear(0.01, $allsells{$curr});
    }

    $template{all_buys}      = \%allbuys;
    $template{all_sells}     = \%allsells;
    $template{all_USD_buys}  = int $allUSDbuys;
    $template{all_USD_sells} = int $allUSDsells;
    $template{all_pl}        = int $allpl;
    my $aggbetsdiff = $firstaggbets - $lastaggbets;
    $template{agg_bets_diff}     = int $aggbetsdiff;
    $template{all_prev_agg_bets} = $allprevaggbets;

    my $start_of_month   = BOM::Utility::Date->new('1-' . $month_to_do);
    my $end_of_mtm       = BOM::Utility::Date->new($mtm_calc_time);
    my $end_of_month     = $start_of_month->plus_time_interval($days_in_month . 'd')->minus_time_interval('1s');
    my $month_completed  = min(1, max(1e-5, ($end_of_mtm->epoch - $start_of_month->epoch) / ($end_of_month->epoch - $start_of_month->epoch)));
    my $projection_ratio = 1 / $month_completed;

    $template{summarize_turnover} = 1;
    my $estimated_pl = int($allpl + $aggbetsdiff);
    $template{estimated_pl}        = $estimated_pl;
    $template{pct_month_completed} = roundnear(0.01, 100 * $month_completed);
    $template{pct_hold}            = roundnear(0.01, 100 * ($estimated_pl / ($allUSDbuys || 1)));
    $template{projected_pl}        = int($estimated_pl * $projection_ratio);
    $template{projected_turnover}  = int($allUSDbuys * $projection_ratio);

    return %template;
}

1;
