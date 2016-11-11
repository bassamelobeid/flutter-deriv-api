package BOM::RPC::v3::CopyTrading::Statistics;

use strict;
use warnings;

use BOM::Platform::Client;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Transaction;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::MarketData qw(create_underlying);

use Performance::Probability qw(get_performance_probability);

use List::Util qw/sum0/;
use Data::Dumper;

sub trader_statistics {
    my $params = shift->{args};

    my $trader = BOM::Platform::Client->new({loginid => $params->{trader_id}});
    my $trader_date_joined = Date::Utility->new($trader->date_joined);

    my $db = BOM::Database::ClientDB->new({
            client_loginid => $trader->loginid,
        })->db;
    my $trader_accounts = [$trader->account];

    # Calculate average performance for multiple accounts
    my $now                       = Date::Utility->new();
    my $monthly_profitable_trades = {};
    my $yearly_profitable_trades  = {};
    my ($last_12months_profitable_trades, $performance_probability);
    for my $account (@{$trader_accounts}) {
        my $txn_dm = BOM::Database::DataMapper::Transaction->new({
            client_loginid => $trader->loginid,
            currency_code  => $account->currency_code,
            db             => $db,
        });

        # trader performance
        my @sorted_monthly_profits;
        for (my $year = $trader_date_joined->year; $year <= $now->year; $year++) {
            my @monthly_profits_of_current_year;
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
                push @{$monthly_profitable_trades->{$year . '-' . $month}}, $current_month_profit;
                push @sorted_monthly_profits,          $current_month_profit;
                push @monthly_profits_of_current_year, $current_month_profit;
            }

            push @{$yearly_profitable_trades->{$year}}, _year_performance(@monthly_profits_of_current_year);
        }

        # last 12 months profitable
        my $last_month_idx = scalar(@sorted_monthly_profits) < 12 ? scalar(@sorted_monthly_profits) : 12;
        push @$last_12months_profitable_trades, _year_performance(@sorted_monthly_profits[-$last_month_idx .. -1]);

        # Performance Probability
        my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new({
            client_loginid => $trader->loginid,
            currency_code  => $account->currency_code,
            db             => $db,
        });

        my $sold_contracts = $fmb_dm->get_sold({
            limit => 9e5,
        });

        my $cumulative_pnl      = 0;
        my $contract_parameters = {};
        foreach my $contract (@{$sold_contracts}) {
            my $start_epoch = Date::Utility->new($contract->{start_time})->epoch;
            my $sell_epoch  = Date::Utility->new($contract->{sell_time})->epoch;

            if ($contract->{bet_type} eq 'CALL' or $contract->{bet_type} eq 'PUT') {
                push @{$contract_parameters->{start_time}},        $start_epoch;
                push @{$contract_parameters->{sell_time}},         $sell_epoch;
                push @{$contract_parameters->{buy_price}},         $contract->{buy_price};
                push @{$contract_parameters->{payout_price}},      $contract->{payout_price};
                push @{$contract_parameters->{bet_type}},          $contract->{bet_type};
                push @{$contract_parameters->{underlying_symbol}}, $contract->{underlying_symbol};

                $cumulative_pnl = $cumulative_pnl + ($contract->{sell_price} - $contract->{buy_price});
            }
        }

        push @$performance_probability,
            sprintf(
            "%.4f",
            1 - Performance::Probability::get_performance_probability({
                    pnl          => $cumulative_pnl,
                    payout       => $contract_parameters->{payout_price},
                    bought_price => $contract_parameters->{buy_price},
                    types        => $contract_parameters->{bet_type},
                    underlying   => $contract_parameters->{underlying_symbol},
                    start_time   => $contract_parameters->{start_time},
                    sell_time    => $contract_parameters->{sell_time},
                }));
    }

    # Average for multiply accounts
    $monthly_profitable_trades->{$_} = _mean(@{$monthly_profitable_trades->{$_}}) for keys %{$monthly_profitable_trades};
    $yearly_profitable_trades->{$_}  = _mean(@{$yearly_profitable_trades->{$_}})  for keys %{$yearly_profitable_trades};
    $last_12months_profitable_trades = _mean(@$last_12months_profitable_trades);
    $performance_probability         = _mean(@$performance_probability);

    # Calculate common trading statistics for multiple accounts
    my $trades_breakdown = {};
    my $trades_statistic = {};
    my ($total_trades, $avg_duration, $trades_profitable);

    my $txn_dm = BOM::Database::DataMapper::Transaction->new({db => $db});

    # trades_cnt
    $total_trades = $txn_dm->get_transactions_cnt(
        $trader_accounts,
        {
            action_type => 'buy',
        });

    # trades average duration
    $avg_duration = $txn_dm->get_trades_avg_duration($trader_accounts);
    ($avg_duration) = ($avg_duration =~ /(.+)\./);

    # trades profitable
    $trades_statistic = $txn_dm->get_trades_profitable($trader_accounts);
    $trades_profitable = $trades_statistic->{'win'}->{count} / ($trades_statistic->{'win'}->{count} + $trades_statistic->{'loss'}->{count});

    # trades_breakdown
    my $symbols_breakdown = $txn_dm->get_symbols_breakdown($trader_accounts);
    for my $symbol_data (@$symbols_breakdown) {
        my $symbol = $symbol_data->[0];
        my $trades = $symbol_data->[1];
        $trades_breakdown->{create_underlying($symbol)->market->name} += $trades;
    }
    for my $market (keys %$trades_breakdown) {
        $trades_breakdown->{$market} = sprintf("%.4f", $trades_breakdown->{$market} / $total_trades);
    }

    return {
        active_since => $trader_date_joined->epoch,
        # performance
        monthly_profitable_trades       => $monthly_profitable_trades,
        yearly_profitable_trades        => $yearly_profitable_trades,
        last_12months_profitable_trades => $last_12months_profitable_trades,
        performance_probability         => $performance_probability,
        # trading
        total_trades      => $total_trades,
        trades_profitable => sprintf("%.4f", $trades_profitable),
        avg_duration      => Date::Utility->new('2000-01-01 ' . $avg_duration)->seconds_after_midnight,
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

sub _mean {
    my @arr = grep { defined $_ && $_ } @_;
    return sum0(@arr) / (scalar(@arr) || 1);
}

1;

__END__
