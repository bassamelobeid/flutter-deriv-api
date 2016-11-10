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

    my $trader             = BOM::Platform::Client->new({loginid => $params->{trader_id}});
    my $trader_date_joined = Date::Utility->new($trader->date_joined);
    my $trader_acc         = $trader->default_account;

    my $db = BOM::Database::ClientDB->new({
            client_loginid => $trader->loginid,
        })->db;
    my $txn_dm = BOM::Database::DataMapper::Transaction->new({
        client_loginid => $trader->loginid,
        currency_code  => 'USD',              # TODO is it neccessary?
        db             => $db,
    });

    # profitable
    my $now                = Date::Utility->new();
    my $monthly_profitable = {};
    my $yearly_profitable  = {};
    for (my $year = $trader_date_joined->year; $year <= $now->year; $year++) {
        for (my $month = 1; $month <= 12; $month++) {
            $month = sprintf("%.2u", $month);
            my $date = Date::Utility->new("$year-$month-01");
            next if $date->month < $trader_date_joined->month and $date->year == $trader_date_joined->year;
            next if $date->month > $now->month and $date->year == $now->year;

            my $first_day_in_current_month = Date::Utility->new($date->year . $date->month . '01000000')->datetime_yyyymmdd_hhmmss;
            my $last_day_in_current_month =
                Date::Utility->new($date->year . $date->month . $date->days_in_month . '235959')->datetime_yyyymmdd_hhmmss;

            my $W = $txn_dm->get_monthly_payments_sum($date, $trader_acc, 'withdrawal');
            my $D = $txn_dm->get_monthly_payments_sum($date, $trader_acc, 'deposit');
            my $E1 = $txn_dm->get_balance_before_date($last_day_in_current_month,  $trader_acc);    # is the equity at the end of the month
            my $E0 = $txn_dm->get_balance_before_date($first_day_in_current_month, $trader_acc);    # is the equity at the beginning of the month

            $monthly_profitable->{$year . '-' . $month} = sprintf("%.4f", ((($E1 + $W) - ($E0 + $D)) / ($E0 + $D)));
        }

        my @profitables =
            map  { $monthly_profitable->{$_} }
            grep { /^$year/ }
            keys %$monthly_profitable;
        my $mult = 1;
        $mult *= 1 + $_ for @profitables;
        $yearly_profitable->{$year} = sprintf("%.4f", $mult - 1);
    }

    # trades_cnt
    my $total_trades = $txn_dm->get_transactions_cnt({
            action_type => 'buy',
        },
        $trader_acc,
    );

    # trades average duration
    my $avg_duration = $txn_dm->get_trades_avg_duration($trader_acc);

    # trades profitable
    my $trades_statistic = $txn_dm->get_trades_profitable($trader_acc);
    my $trades_profitable = $trades_statistic->{'win'}->{count} / ($trades_statistic->{'win'}->{count} + $trades_statistic->{'loss'}->{count});

    # trades_breakdown
    my $trades_breakdown  = {};
    my $symbols_breakdown = $txn_dm->get_symbols_breakdown($trader_acc);
    for my $symbol_data (@$symbols_breakdown) {
        my $symbol = $symbol_data->[0];
        my $trades = $symbol_data->[1];
        $trades_breakdown->{create_underlying($symbol)->market->name} += $trades;
    }
    for my $market (keys %$trades_breakdown) {
        $trades_breakdown->{$market} = sprintf("%.4f", $trades_breakdown->{$market} / $total_trades);
    }

    return {
        active_since => $trader->date_joined,
        # performance
        monthly_profitable => $monthly_profitable,
        yearly_profitable  => $yearly_profitable,
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

1;

__END__
