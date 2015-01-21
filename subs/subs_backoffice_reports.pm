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

### DailyTurnOverReport ####################
# Purpose: Total display daily turn over report
#################################################
sub DailyTurnOverReport {
    my ($args, $options) = @_;

    my $report_mapper = BOM::Platform::Data::Persistence::DataMapper::CollectorReporting->new({broker_code => 'FOG'});

    if ($args->{month} !~ /^\w{3}-\d{2}$/) {
        print "<p>Invalid month $args->{month}</p>";
        code_exit_BO();
    }

    my $mtm_calc_time = $report_mapper->get_last_generated_historical_marked_to_market_time();
    my $initial_note =
        ($args->{whattodo} eq 'TURNOVER' ? '(BUY-SELL represents the company profit)' : '(CREDIT-DEBIT represents the client deposits)');
    my @all_currencies = BOM::Platform::Runtime->instance->landing_companies->all_currencies;
    my %rates = map { $_ => ($args->{$_} || in_USD(1, $_)) } @all_currencies;

    my %template = (
        mtm_calc_time => $mtm_calc_time,
        initial_note  => $initial_note,
        risk_report   => request()->url_for("backoffice/quant/risk_dashboard.cgi"),
        currencies    => \@all_currencies,
        rates         => \%rates,
        buy_label     => ($args->{whattodo} eq 'TURNOVER' ? 'BUY' : 'CREDIT'),
        sell_label    => ($args->{whattodo} eq 'TURNOVER' ? 'SELL' : 'DEBIT'),
        days          => [],
    );

    my ($action_bb,   $action_ss);
    my ($lastaggbets, $allprevaggbets);

    if ($args->{whattodo} eq 'TURNOVER') {
        $action_bb = 'buy';
        $action_ss = 'sell';
    } else {
        $action_bb = 'deposit';
        $action_ss = 'withdrawal';
    }

    my $now         = BOM::Utility::Date->new;
    my $month_to_do = $args->{month};
    my $this_month  = ($now->date_ddmmmyy =~ /$month_to_do/) ? 1 : 0;    # A rather inelegant way to see if we are doing this month.

    my $currdate = BOM::Utility::Date->new('1-' . $args->{'month'});
    my $prevdate = BOM::Utility::Date->new($currdate->epoch - 86400)->date_ddmmmyy;

    my $prevaggbets  = int(USD_AggregateOutstandingBets_ongivendate($prevdate));
    my $firstaggbets = $prevaggbets;

    my (%allbuys, %allsells);
    my ($allUSDsells, $allUSDbuys, $allpl);

    my $cache_prefix = 'DTR_AGG_SUM';
    my $cache_key    = $mtm_calc_time;
    $cache_key =~ s/\s//g;
    my $aggregate_transactions;
    if ($this_month and my $cached = Cache::RedisDB->get($cache_prefix, $cache_key)) {
        $aggregate_transactions = from_json($cached);
    } else {
        $aggregate_transactions = $report_mapper->get_aggregated_sum_of_transactions_of_month({
            date => $currdate->db_timestamp,
            type => ($args->{whattodo} eq 'TURNOVER') ? 'bet' : 'payment',
        });
        Cache::RedisDB->set($cache_prefix, $cache_key, to_json($aggregate_transactions), 3600)
            if ($this_month);    # Hold current month for up to an hour.
    }

    my $eod_market_values = BOM::Platform::Data::Persistence::DataMapper::HistoricalMarkedToMarket->new({
            broker_code => 'FOG',
            operation   => 'collector'
        })->eod_market_values_of_month($currdate->db_timestamp);

    $cache_prefix = 'ACTIVE_CLIENTS';
    my $active_clients;
    if ($this_month and my $cached = Cache::RedisDB->get($cache_prefix, $cache_key)) {
        $active_clients = from_json($cached);
    } else {
        $active_clients = $report_mapper->number_of_active_clients_of_month($currdate->db_timestamp);
        Cache::RedisDB->set($cache_prefix, $cache_key, to_json($active_clients), 3600)
            if ($this_month);    # Hold current month for up to an hour.
    }

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

    if ($args->{'whattodo'} eq 'TURNOVER') {
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
    }

    return %template;
}

1;
