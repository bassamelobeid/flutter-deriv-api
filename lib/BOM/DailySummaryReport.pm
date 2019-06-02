package BOM::DailySummaryReport;

use Moose;

use Date::Utility;
use Path::Tiny;
use IO::File;
use Try::Tiny;
use Format::Util::Numbers qw/formatnumber/;

use BOM::Database::ClientDB;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Database::DataMapper::Transaction;

has save_file => (
    is      => 'ro',
    default => 1,
);

has [qw(for_date currencies brokercodes broker_path)] => (
    is       => 'ro',
    required => 1,
);

has [qw(collector_dbic)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_collector_dbic {
    my $self = shift;

    return BOM::Database::ClientDB->new({
            broker_code => 'FOG',
            operation   => 'collector',
        })->db->dbic;
}

sub generate_report {
    my $self = shift;
    return $self->collector_dbic->run(ping => sub { $self->_generate_report($_) });
}

sub _generate_report {
    my ($self, $dbh) = @_;
    local $dbh->{AutoCommit} = 0;
    my $run_for           = Date::Utility->new($self->for_date);
    my $start_of_next_day = Date::Utility->new($run_for->epoch - $run_for->seconds_after_midnight)->datetime_iso8601;
    my $total_pl;

    foreach my $currency (sort @{$self->currencies}) {
        foreach my $broker (sort @{$self->brokercodes}) {
            # We don't care about these for Virtuals.
            if ($broker !~ /^\w+$/ or $broker =~ /^VR/ or $broker eq 'FOG') {
                next;
            }

            my $now = Date::Utility->new;
            local $\ = "\n";
            my $fileext = ($currency eq 'USD') ? "" : '.' . $currency;

            # Get all of the clients in the DB with this broker code/currency combo, their balance and their agg deposits and withdrawals
            my $client_ref = $self->get_client_details($currency, $broker, $start_of_next_day);
            my $accounts_with_open_bet = $self->get_open_contracts($currency, $broker, $start_of_next_day);
            # LOOP THROUGH ALL THE CLIENTS
            my @sum_lines;
            my $agg_total_open_bets_profit = 0;
            CLIENT:
            foreach my $login_id (sort keys %{$client_ref}) {
                my $account_id  = $client_ref->{$login_id}->{'account_id'};
                my $acbalance   = $client_ref->{$login_id}->{'balance_at'};
                my $balance_sql = q{
                INSERT INTO accounting.end_of_day_balances (
                 account_id, effective_date, balance
                )
                VALUES(?,?,?)
                ON CONFLICT (account_id, effective_date)
                DO UPDATE
                SET balance = EXCLUDED.balance
                RETURNING id
                };

                my @eod_id = $dbh->selectrow_array($balance_sql, {}, ($account_id, $self->for_date, $acbalance));

                # Only execute this part if client had open bets at that time.
                my @portfolios;
                my $total_open_bets_value  = 0;
                my $total_open_bets_profit = 0;

                if (exists $accounts_with_open_bet->{$account_id}) {
                    my $bets_ref = $accounts_with_open_bet->{$account_id};

                    foreach my $bet_id (keys %{$bets_ref}) {
                        my $bet = $bets_ref->{$bet_id};
                        my $theo;

                        try {
                            my $contract = produce_contract($bet->{short_code}, $currency);
                            $theo = $contract->is_binary ? $contract->theo_price : $contract->theo_price * $contract->multiplier;
                            return 0;
                        }
                        catch {
                            warn("theo price error[$_], bet_id[" . $bet_id . "], account_id[$account_id], end_of_day_balance_id[" . $eod_id[0] . "]");
                            return 1;
                        } and next;

                        my $open_position_sql = q{
                INSERT INTO accounting.end_of_day_open_positions
                    (end_of_day_balance_id, financial_market_bet_id, marked_to_market_value)
                    VALUES(?,?,?)
                };

                        my $open_position_statement = $dbh->prepare($open_position_sql);
                        $open_position_statement->execute(($eod_id[0], $bet_id, $theo));

                        my $portfolio = "1L $bet->{buy_price} $bet->{short_code} ($theo)";
                        push @portfolios, $portfolio;

                        $total_open_bets_value  += $theo;
                        $total_open_bets_profit += ($theo - $bet->{buy_price});
                    }
                }

                # open positions value minus buy prices
                $agg_total_open_bets_profit += $total_open_bets_profit;

                my $summary_line = join(
                    ',',
                    (
                        $login_id,
                        formatnumber('amount', $currency, $acbalance),
                        $total_open_bets_value,
                        formatnumber('amount', $currency, $total_open_bets_profit),
                        formatnumber('amount', $currency, $total_open_bets_value + $acbalance),
                        formatnumber('amount', $currency, $client_ref->{$login_id}->{'deposits'} + $client_ref->{$login_id}->{'withdrawals'})));
                $summary_line .= ',' . join('+', @portfolios) if scalar @portfolios;
                push @sum_lines, $summary_line . "\n";
            }

            if (scalar keys %{$client_ref} > 0) {
                $dbh->commit;
            }

            if ($self->save_file) {
                my $broker_path = $self->broker_path . $broker . '/';
                my $ds_path     = $broker_path . 'dailysummary/';
                Path::Tiny::path($ds_path)->mkpath if (not -d $ds_path);

                my $summary     = $ds_path . $run_for->date_ddmmmyy . '.summary' . $fileext;
                my $tempsummary = $summary . '.temp';
                my $sm_fh       = IO::File->new('> ' . $tempsummary) || die '[' . $0 . '] Can\'t write to ' . $tempsummary . ' ' . $!;
                my $generation_msg =
                      '#File generated for '
                    . $run_for->date . ' on '
                    . $now->datetime
                    . ' from entire database since inception by f_consolidated.cgi ('
                    . $currency . ")\n";

                my $header =
                    "loginid,account_balance,total_open_bets_value,total_open_bets_profit,total_equity,aggregate_deposit_withdrawals,portfolio\n";
                print $sm_fh ($generation_msg, $header, @sum_lines);
                close $sm_fh;
                rename($tempsummary, $summary);
            }
            $total_pl->{$broker}->{$currency} = formatnumber('amount', $currency, $agg_total_open_bets_profit);
        }
    }

    return $total_pl;
}

sub get_client_details {
    my ($self, $currency, $broker, $date) = @_;

    my $db = $self->get_bo_replica_db_for($broker);

    return BOM::Database::DataMapper::Transaction->new({
            db => $db,
        }
        )->get_daily_summary_report({
            currency_code     => $currency,
            broker_code       => $broker,
            start_of_next_day => $date,
        });
}

sub get_open_contracts {
    my ($self, $currency, $broker, $date) = @_;

    my $db = $self->get_bo_replica_db_for($broker);
    return BOM::Database::DataMapper::Transaction->new({
            db => $db,
        }
        )->get_accounts_with_open_bets_at_end_of({
            currency_code     => $currency,
            broker_code       => $broker,
            start_of_next_day => $date,
        });

}

sub get_bo_replica_db_for {
    my ($self, $broker) = @_;

    my $db = BOM::Database::ClientDB->new({
            broker_code => $broker,
            operation   => 'backoffice_replica'
        })->db;

    return $db;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
