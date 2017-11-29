package BOM::RPC::v3::CopyTrading::Statistics;

use strict;
use warnings;

use Try::Tiny;
use Performance::Probability qw(get_performance_probability);

use Client::Account;

use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Transaction;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::DataMapper::Copier;
use BOM::MarketData qw(create_underlying);
use BOM::Platform::Context qw (localize);
use BOM::Platform::RedisReplicated;

sub copytrading_statistics {
    my $params = shift->{args};

    my $trader_id = uc $params->{trader_id};
    my $trader = try { Client::Account->new({loginid => $trader_id, db_operation => 'replica'}) };
    unless ($trader) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'WrongLoginID',
                message_to_client => localize('Login ID ([_1]) does not exist.', $trader_id)});
    }

    # Check that client allows copy trading
    unless ($trader->allow_copiers) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'CopyTradingNotAllowed',
                message_to_client => localize('Trader does not allow copy trading.')});
    }

    my $trader_date_joined = Date::Utility->new($trader->date_joined);
    my $result_hash        = {
        active_since => $trader_date_joined->epoch,
        # performance
        monthly_profitable_trades       => {},
        yearly_profitable_trades        => {},
        last_12months_profitable_trades => 0,
        performance_probability         => 1,
        # trading
        total_trades      => 0,
        trades_profitable => 0,
        avg_duration      => 0,
        avg_profit        => 0,
        avg_loss          => 0,
        trades_breakdown  => {},
        # copiers
        copiers => BOM::Database::DataMapper::Copier->new(
            broker_code => $trader->broker_code,
            operation   => 'replica'
        )->get_copiers_cnt({trader_id => $trader_id}),
    };

    my $account = $trader->default_account;

    # Check that client has accounts
    unless ($account) {
        return $result_hash;
    }

    my $db = BOM::Database::ClientDB->new({
            client_loginid => $trader->loginid,
        })->db;

    # Calculate average performance for multiple accounts
    my $currency = $account->currency_code;
    my $txn_dm   = BOM::Database::DataMapper::Transaction->new({
        client_loginid => $trader->loginid,
        currency_code  => $currency,
        db             => $db,
        operation      => 'replica',
    });

    # trader performance
    for my $row (@{$txn_dm->get_monthly_payments_sum()}) {
        my ($year, $month, $D, $W) = @$row;
        $result_hash->{monthly_profitable_trades}->{$year . '-' . $month}->{deposit}    = $D;
        $result_hash->{monthly_profitable_trades}->{$year . '-' . $month}->{withdrawal} = $W;
    }
    for my $row (@{$txn_dm->get_monthly_balance()}) {
        my ($year, $month, $E0, $E1) = @$row;
        $result_hash->{monthly_profitable_trades}->{$year . '-' . $month}->{E0} = $E0;
        $result_hash->{monthly_profitable_trades}->{$year . '-' . $month}->{E1} = $E1;
    }
    my @sorted_monthly_profits;
    for my $date (sort keys %{$result_hash->{monthly_profitable_trades}}) {
        my ($year) = ($date =~ /(\d{4})/);
        my $D      = $result_hash->{monthly_profitable_trades}->{$date}->{deposit};
        my $W      = $result_hash->{monthly_profitable_trades}->{$date}->{withdrawal};
        my $E0     = $result_hash->{monthly_profitable_trades}->{$date}->{E0};
        my $E1     = $result_hash->{monthly_profitable_trades}->{$date}->{E1};
        my $current_month_profit = sprintf("%.4f", ((($E1 + $W) - ($E0 + $D)) / ($E0 + $D)));
        $result_hash->{monthly_profitable_trades}->{$date} = $current_month_profit;
        push @sorted_monthly_profits, $current_month_profit;
        push @{$result_hash->{yearly_profitable_trades}->{$year}}, $current_month_profit;
    }
    for my $year (keys %{$result_hash->{yearly_profitable_trades}}) {
        $result_hash->{yearly_profitable_trades}->{$year} = _year_performance($currency, @{$result_hash->{yearly_profitable_trades}->{$year}});
    }

    # last 12 months profitable
    my $last_month_idx = scalar(@sorted_monthly_profits) < 12 ? scalar(@sorted_monthly_profits) : 12;
    $result_hash->{last_12months_profitable_trades} = _year_performance($currency, @sorted_monthly_profits[-$last_month_idx .. -1]);

    # Performance Probability
    my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new({
        client_loginid => $trader->loginid,
        currency_code  => $currency,
        db             => $db,
        operation      => 'replica',
    });

    my $sold_contracts = $fmb_dm->get_sold({
        limit => 100,
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
    # Ren: the model doesn’t work because if there are too few contract
    # let’s try if client has at least 50 contracts
    # let Ren know if there are still errors
    if (scalar(grep { $_->{bet_type} =~ /^(call|put)$/i } @{$sold_contracts}) > 50) {
        try {
            $result_hash->{performance_probability} = sprintf(
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
        catch {
            warn "Performance probability calculation error: $_";
        };
    }

    # trades average duration
    $result_hash->{avg_duration} = sprintf("%u", BOM::Platform::RedisReplicated::redis_read->get("COPY_TRADING_AVG_DURATION:$trader_id") || 0);

    # trades profitable && total trades count
    my $win_trades  = BOM::Platform::RedisReplicated::redis_read->get("COPY_TRADING_PROFITABLE:$trader_id:win")  || 0;
    my $loss_trades = BOM::Platform::RedisReplicated::redis_read->get("COPY_TRADING_PROFITABLE:$trader_id:loss") || 0;
    $result_hash->{total_trades} = $win_trades + $loss_trades;
    $result_hash->{trades_profitable} = sprintf("%.4f", $win_trades / ($result_hash->{total_trades} || 1));
    $result_hash->{avg_profit} =
        sprintf("%.4f", BOM::Platform::RedisReplicated::redis_read->get("COPY_TRADING_AVG_PROFIT:$trader_id:win") || 0);
    $result_hash->{avg_loss} =
        sprintf("%.4f", BOM::Platform::RedisReplicated::redis_read->get("COPY_TRADING_AVG_PROFIT:$trader_id:loss") || 0);

    # trades_breakdown
    my %symbols_breakdown = @{BOM::Platform::RedisReplicated::redis_read->hgetall("COPY_TRADING_SYMBOLS_BREAKDOWN:$trader_id")};
    for my $symbol (keys %symbols_breakdown) {
        my $trades = $symbols_breakdown{$symbol};
        $result_hash->{trades_breakdown}->{create_underlying($symbol)->market->name} += $trades;
    }
    for my $market (keys %{$result_hash->{trades_breakdown}}) {
        $result_hash->{trades_breakdown}->{$market} =
            sprintf("%.4f", $result_hash->{trades_breakdown}->{$market} / $result_hash->{total_trades});
    }

    return $result_hash;
}

sub _year_performance {
    my ($currency, @months) = @_;
    my $profits_mult = 1;
    $profits_mult *= 1 + $_ for @months;
    return sprintf("%.4f", $profits_mult - 1);
}

1;

__END__
