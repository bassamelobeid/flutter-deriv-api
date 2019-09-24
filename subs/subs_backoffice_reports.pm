## no critic (RequireExplicitPackage)
use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use Date::Manip;
use JSON::MaybeXS;
use List::Util qw( min max );
use Cache::RedisDB;
use Format::Util::Numbers qw/roundcommon financialrounding/;
use ExchangeRates::CurrencyConverter qw/in_usd/;

use LandingCompany::Registry;
use BOM::Config::Runtime;

sub DailyTurnOverReport {
    my ($args, $options) = @_;

    if ($args->{month} !~ /^\w{3}-\d{2}$/) {
        code_exit_BO("<p>Invalid month $args->{month}</p>");
    }

    my $initial_note   = '(BUY-SELL represents the company profit)';
    my @all_currencies = LandingCompany::Registry->new()->all_currencies({exclude_experimental => 1});
    my %rates          = map { $_ => in_usd(1, $_) } grep { $_ !~ /^(?:ETC|BCH)$/ } @all_currencies;

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
        next if $when->epoch > Date::Utility->new->epoch;
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

1;
