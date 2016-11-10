package BOM::RPC::v3::CopyTrading::Statistics;

use strict;
use warnings;

use BOM::Platform::Client;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Transaction;
use BOM::MarketData qw(create_underlying);

use Data::Dumper;

sub trader_statistics {
    my $params = shift->{args};

    my $trader = BOM::Platform::Client->new({loginid => $params->{trader_id}});
    my $trader_date_joined = Date::Utility->new($trader->date_joined);

    my $db = BOM::Database::ClientDB->new({
            client_loginid => $trader->loginid,
        })->db;

    my $now                       = Date::Utility->new();
    my $monthly_profitable_trades = {};
    my $yearly_profitable_trades  = {};
    my $trades_breakdown          = {};
    my $trades_statistic          = {};
    my ($total_trades, $avg_duration, $trades_profitable, $last_12months_profitable_trades);

    for my $account ($trader->account) {
        my $txn_dm = BOM::Database::DataMapper::Transaction->new({
            client_loginid => $trader->loginid,
            currency_code  => $account->currency_code,
            db             => $db,
        });

        # trader performance
        my @sorted_monthly_profits;
        for (my $year = $trader_date_joined->year; $year <= $now->year; $year++) {
            for (my $month = 1; $month <= 12; $month++) {
                $month = sprintf("%.2u", $month);
                my $date = Date::Utility->new("$year-$month-01");
                next if $date->month < $trader_date_joined->month and $date->year == $trader_date_joined->year;
                next if $date->month > $now->month and $date->year == $now->year;

                my $first_day_in_current_month = Date::Utility->new($date->year . $date->month . '01000000')->datetime_yyyymmdd_hhmmss;
                my $last_day_in_current_month =
                    Date::Utility->new($date->year . $date->month . $date->days_in_month . '235959')->datetime_yyyymmdd_hhmmss;

                my $W = $txn_dm->get_monthly_payments_sum($date, 'withdrawal');
                my $D = $txn_dm->get_monthly_payments_sum($date, 'deposit');
                my $E1 = $txn_dm->get_balance_before_date($last_day_in_current_month);     # is the equity at the end of the month
                my $E0 = $txn_dm->get_balance_before_date($first_day_in_current_month);    # is the equity at the beginning of the month

                my $current_month_profit = sprintf("%.4f", ((($E1 + $W) - ($E0 + $D)) / ($E0 + $D)));
                $monthly_profitable_trades->{$year . '-' . $month} = $current_month_profit;
                push @sorted_monthly_profits, $current_month_profit;
            }

            my @monthly_profits =
                map  { $monthly_profitable_trades->{$_} }
                grep { /^$year/ }
                keys %$monthly_profitable_trades;
            $yearly_profitable_trades->{$year} = _year_performance(@monthly_profits);
        }

        # last 12 months profitable
        my $last_month_idx = scalar(@sorted_monthly_profits) < 12 ? scalar(@sorted_monthly_profits) : 12;
        $last_12months_profitable_trades = _year_performance(@sorted_monthly_profits[-$last_month_idx .. -1]);

        # trades_cnt
        $total_trades = $txn_dm->get_transactions_cnt({
            action_type => 'buy',
        });

        # trades average duration
        $avg_duration = $txn_dm->get_trades_avg_duration();

        # trades profitable
        $trades_statistic = $txn_dm->get_trades_profitable();
        $trades_profitable = $trades_statistic->{'win'}->{count} / ($trades_statistic->{'win'}->{count} + $trades_statistic->{'loss'}->{count});

        # trades_breakdown
        my $symbols_breakdown = $txn_dm->get_symbols_breakdown();
        for my $symbol_data (@$symbols_breakdown) {
            my $symbol = $symbol_data->[0];
            my $trades = $symbol_data->[1];
            $trades_breakdown->{create_underlying($symbol)->market->name} += $trades;
        }
        for my $market (keys %$trades_breakdown) {
            $trades_breakdown->{$market} = sprintf("%.4f", $trades_breakdown->{$market} / $total_trades);
        }
    }

    return {
        active_since => $trader_date_joined->date,
        # performance
        monthly_profitable_trades       => $monthly_profitable_trades,
        yearly_profitable_trades        => $yearly_profitable_trades,
        last_12months_profitable_trades => $last_12months_profitable_trades,
        # trading
        total_trades      => $total_trades,
        trades_profitable => sprintf("%.4f", $trades_profitable),
        avg_duration      => $avg_duration,
        avg_profit        => sprintf("%.4f", $trades_statistic->{'win'}->{avg}),
        avg_loss          => sprintf("%.4f", $trades_statistic->{'loss'}->{avg}),
        trades_breakdown  => $trades_breakdown,
        # copiers
        copiers => 0,    # TODO
    };
}

sub _year_performance {
    my (@months) = @_;
    my $profits_mult = 1;
    $profits_mult *= 1 + $_ for @months;
    return sprintf("%.4f", $profits_mult - 1);
}

1;

__END__
