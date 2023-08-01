package BOM::Database::DataMapper::Transaction;

=head1 NAME

BOM::Database::DataMapper::Transaction

=head1 DESCRIPTION

This is a class that will collect general transaction queries.

=head1 VERSION

0.1

=cut

use Moose;
use Scalar::Util qw(looks_like_number);
use BOM::Database::AutoGenerated::Rose::Transaction::Manager;
use BOM::Database::AutoGenerated::Rose::Account::Manager;
use BOM::Database::Model::Constants;
use BOM::Database::Model::Transaction;
use BOM::Database::Model::Constants;
use Date::Utility;
use Carp;
extends 'BOM::Database::DataMapper::AccountBase';

has '_mapper_model_class' => (
    is       => 'ro',
    isa      => 'Str',
    init_arg => undef,
    default  => 'BOM::Database::Model::Transaction',
);

sub get_daily_summary_report {
    my $self = shift;
    my $args = shift;

    my $start_of_next_day = $args->{'start_of_next_day'};
    my $broker_code       = $args->{'broker_code'};
    my $currency_code     = $args->{'currency_code'};

    my $dbic = $self->db->dbic;

    my $sql = q{
        SELECT
                a.id as account_id,
                a.client_loginid AS loginid,
                a.balance- COALESCE(balance_table.balance_at,0) as balance_at,
                COALESCE(payment_table.deposits,0) as deposits,
                COALESCE(payment_table.withdrawals,0) as withdrawals
        FROM

            transaction.account a
        LEFT JOIN
        (
            SELECT
                tran.account_id AS account_id,
                acc.client_loginid AS loginid,
                balance,
                SUM(tran.amount) as balance_at
            FROM
                transaction.transaction AS tran,
                transaction.account as acc
            WHERE
                acc.currency_code= $1
                AND substring(client_loginid from $2)<>''
                AND tran.account_id = acc.id
                AND tran.transaction_time >= $3::date
            GROUP BY
                tran.account_id,
                acc.client_loginid,
                balance
        ) balance_table ON (balance_table.account_id=a.id)
        LEFT JOIN
        (
            SELECT
                account_id,
                SUM(CASE WHEN amount>0 THEN amount ELSE 0 END) as deposits,
                SUM(CASE WHEN amount<0 THEN amount ELSE 0 END) as withdrawals
            FROM
                payment.payment
            WHERE
                payment_time < $3::date::timestamp
/*
There have been cases where a transaction_time was in one month and a payment_time in another month by only ms
 amount |    payment_time     |      transaction_time      | payment_id | client_loginid 
--------+---------------------+----------------------------+------------+----------------
  -5.00 | 2021-07-01 00:00:00 | 2021-06-30 23:59:59.533795 |  854554581 | CR1018706

In a case like that, the payment is not picked up for June EOM,
but Metabase doesn't use payment_time, but rather transaction_time... and oh the raucus caused in Accounting recon when that happens.

So here, we hack in a look for a payment that matches that condition by considering the last minute of txns and pulling in the associated payment even if it falls in the next month.

In production CR, this condition doesn't really change the execution time of this subquery which is currently between 50 & 60s

Someday we'll get rid of this legacy code boat anchor...
*/
               OR id IN (
                    SELECT p.id
                    FROM payment.payment p
                    JOIN transaction.transaction t
                         ON  t.payment_id=p.id
                         AND t.transaction_time > $3::date::timestamp - INTERVAL '1m'
                         AND t.transaction_time < $3::date::timestamp
                   )
            GROUP BY
                account_id
        ) payment_table ON (payment_table.account_id=a.id)

        WHERE
                a.currency_code= $1
                AND substring(client_loginid from $2)<>''
        ORDER BY
            a.id
    };

    return $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);

            $sth->bind_param(1, $currency_code);
            $sth->bind_param(2, '^' . $broker_code . '[0-9]+');
            $sth->bind_param(3, $start_of_next_day);

            $sth->execute();

            return $sth->fetchall_hashref('loginid');
        });
}

sub get_accounts_with_open_bets_at_end_of {
    my $self = shift;
    my $args = shift;

    my $start_of_next_day = $args->{'start_of_next_day'};
    my $broker_code       = $args->{'broker_code'};
    my $currency_code     = $args->{'currency_code'};

    my $dbic = $self->db->dbic;

    my $sql = <<'SQL';
SELECT b.*
  FROM (
     SELECT *
       FROM bet.financial_market_bet_open fmb
       LEFT JOIN bet.multiplier m on m.financial_market_bet_id=fmb.id
      WHERE bet_class NOT IN ('legacy_bet', 'run_bet')
        AND purchase_time < $3::TIMESTAMP

      UNION ALL

     SELECT *
       FROM bet.financial_market_bet fmb
       LEFT JOIN bet.multiplier m on m.financial_market_bet_id=fmb.id
      WHERE is_sold
        AND bet_class NOT IN ('legacy_bet', 'run_bet')
        AND purchase_time < $3::TIMESTAMP
        AND sell_time    >= $3::TIMESTAMP
     ) b
  JOIN transaction.account a
    ON a.id = b.account_id
 WHERE a.currency_code  = $1
   AND a.client_loginid ~ ('^' || $2 || '[0-9]')
SQL

    my $open_bets = $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);

            $sth->bind_param(1, $currency_code);
            $sth->bind_param(2, $broker_code);
            $sth->bind_param(3, $start_of_next_day);

            $sth->execute();
            return $sth->fetchall_hashref('id');
        });

    my $accounts_with_open_bet;
    foreach my $id (keys %{$open_bets}) {
        my $account_id = $open_bets->{$id}->{account_id};
        $accounts_with_open_bet->{$account_id}->{$id} = $open_bets->{$id};
    }

    return $accounts_with_open_bet;
}

=head2 get_turnover_of_account

Get turnover of account (currency based).

=cut

sub get_turnover_of_account {
    my $self = shift;

    my $sql = q{
        SELECT
            coalesce(SUM(-1*amount), 0) as turnover
        FROM
            transaction.account a,
            transaction.transaction t
        WHERE
            a.client_loginid = ?
            AND a.currency_code=?
            AND a.id = t.account_id
            AND t.action_type='buy'
    };

    my $dbic                = $self->db->dbic;
    my $transaction_hashref = $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute($self->client_loginid, $self->currency_code);
            return $sth->fetchrow_hashref;
        });

    if ($transaction_hashref) {
        return $transaction_hashref->{'turnover'};
    }

    return 0;
}

=head2 get_reality_check_data_of_account

    my $start_time = Date::Utility->new;
    my $result = $mapper->get_reality_check_data_of_account($start_time);
    for my $el (@$result) {
        @data = @{$el}{qw/currency_code id buy_amount sell_amount buy_count sell_count open_cnt pot_profit/}
    }

=cut

sub get_reality_check_data_of_account {
    my $self       = shift;
    my $start_time = shift;
    my $dbic       = $self->db->dbic;

    my $sql = <<'SQL';
SELECT tt.currency_code,
       tt.id,
       coalesce(-tt.buy_amount, 0) AS buy_amount,
       coalesce(tt.sell_amount, 0) AS sell_amount,
       coalesce(tt.buy_count, 0) AS buy_count,
       coalesce(tt.sell_count, 0) AS sell_count,
       coalesce(bb.open_cnt, 0) AS open_cnt,
       coalesce(bb.pot_profit, 0) AS pot_profit
  FROM (SELECT a.currency_code,
               a.id,
               SUM(CASE WHEN t.action_type = 'buy'  THEN t.amount END) AS buy_amount,
               SUM(CASE WHEN t.action_type = 'sell' THEN t.amount END) AS sell_amount,
               SUM(CASE WHEN t.action_type = 'buy'  THEN 1 END) AS buy_count,
               SUM(CASE WHEN t.action_type = 'sell' THEN 1 END) AS sell_count
          FROM transaction.account a
          LEFT JOIN transaction.transaction t
            ON a.id=t.account_id
           AND t.transaction_time >= $2
           AND (t.action_type = 'buy' OR t.action_type = 'sell')
         WHERE a.client_loginid = $1
         GROUP BY 1, 2) tt
  LEFT JOIN LATERAL (SELECT count(*) AS open_cnt,
                            SUM(b.payout_price-b.buy_price) AS pot_profit
                       FROM bet.financial_market_bet b
                      WHERE b.account_id=tt.id
                        AND NOT b.is_sold) bb ON true
 ORDER BY 1
SQL

    return $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute($self->client_loginid, $start_time->db_timestamp);

            return $sth->fetchall_arrayref({});
        });
}

=head2 $self->get_payments($parameters)

Return list of deposit/withdrawal transactions.

=over 2

=item before

Get only the payments made before this date. If not provided its all payments before now.

=item after

Get only the payments made after this date. If not provided its all payments after '1970-01-01 00:00:00'

=back

=cut

sub get_payments {
    my ($self, $args) = @_;

    my $sql = q{
        SELECT
            t.*,
            p.remark AS payment_remark,
            p.payment_type_code AS payment_type
        FROM
            (
                SELECT * FROM transaction.transaction
                WHERE
                    account_id = $1
                    AND transaction_time < $2
                    AND transaction_time > $3
                    AND payment_id IS NOT NULL
                ORDER BY transaction_time ##SORT_ORDER##
                LIMIT $4
            ) t,
            payment.payment p
        WHERE
            t.payment_id = p.id
        ORDER BY t.transaction_time DESC
    };

    my $sort_order = ($args->{after} and not $args->{before}) ? 'ASC' : 'DESC';
    $sql =~ s/##SORT_ORDER##/$sort_order/g;

    my $before = $args->{before} || Date::Utility->new()->datetime_yyyymmdd_hhmmss;
    my $after  = $args->{after}  || '1970-01-01 00:00:00';
    my $limit  = $args->{limit}  || 50;

    my $dbic = $self->db->dbic;
    return $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);

            $sth->bind_param(1, $self->account->id);
            $sth->bind_param(2, $before);
            $sth->bind_param(3, $after);
            $sth->bind_param(4, $limit);

            my $payments = [];
            if ($sth->execute()) {
                while (my $row = $sth->fetchrow_hashref()) {
                    $row->{date} = Date::Utility->new($row->{transaction_time});
                    push @$payments, $row;
                }
            }
            return $payments;
        });
}

sub get_monthly_payments_sum {
    my ($self) = @_;

    my $sql = q{
        SELECT extract(year from payment_time),
               extract(month from payment_time),
               @ sum(CASE WHEN amount > 0 THEN amount ELSE 0 END) deposit,
               @ sum(CASE WHEN amount < 0 THEN amount ELSE 0 END) withdrawal
          FROM payment.payment
         WHERE account_id = $1
           AND payment_time >= '2016-06-01'::TIMESTAMP
      GROUP BY 1, 2
      ORDER BY 1, 2
    };

    my @binds = ($self->account->id);
    return $self->db->dbic->run(fixup => sub { $_->selectall_arrayref($sql, undef, @binds) });
}

sub get_monthly_balance {
    my ($self) = @_;

    # Limit selecting time range to decrease DB load
    my $sql = q{
        SELECT  t2.year, t2.month, max(t2.E0) AS E0, max(t2.E1) AS E1
        FROM (
            SELECT  t1.year, t1.month,
                    CASE WHEN t1.transaction_time = t1.min_time THEN balance_before
                    END AS E0,
                    CASE WHEN t1.transaction_time = t1.max_time THEN balance_after
                    END AS E1
            FROM (
                SELECT account_id,
                       balance_after,
                       (balance_after - amount) balance_before,
                       transaction_time,
                       extract(year from transaction_time) AS year,
                       extract(month from transaction_time) AS month,
                       max(transaction_time) over (partition by extract(year from transaction_time), extract(month from transaction_time)) AS max_time,
                       min(transaction_time) over (partition by extract(year from transaction_time), extract(month from transaction_time)) AS min_time
                FROM   transaction.transaction
                WHERE  account_id = $1
                  AND  transaction_time >= '2016-06-01'::TIMESTAMP
                ORDER BY transaction_time
            ) as t1
            WHERE t1.transaction_time = t1.max_time OR t1.transaction_time = t1.min_time
        ) AS t2
        GROUP BY t2.year, t2.month;
    };

    my @binds = ($self->account->id);
    return $self->db->dbic->run(fixup => sub { $_->selectall_arrayref($sql, undef, @binds) });
}

sub unprocessed_bets {
    my ($self, $last_processed_id, $unsold_ids) = @_;

    my @binds = ($self->account->id, $last_processed_id);
    $unsold_ids //= [];

    # Limit selecting time range to decrease DB load
    my $sql = q{
        SELECT * from betonmarkets.get_unprocessed_bets(?, ?, ?)
    };

    return $self->db->dbic->run(fixup => sub { $_->selectall_arrayref($sql, undef, @binds, $unsold_ids) });
}

=head2 $self->get_transactions($parameters)

Return list of transactions satisfying given parameters. Acceptable parameters are follows:

=over 3

=item before

Get the transactions made before this date. If not provided its all payments before now.

=item after

Get the transactions made after this date. If not provided its all payments after '1970-01-01 00:00:00'

=item limit

Get these many number of transaction after the after date. If not provided we provide 50 transactions.

=back

=cut

sub get_transactions {
    my ($self, $args) = @_;

    my $sql = q{
            SELECT
                t.*,
                m.multiplier,
                m.basis_spot,
                m.stop_out_order_date,
                m.stop_out_order_amount,
                m.take_profit_order_date,
                m.take_profit_order_amount,
                m.stop_loss_order_date,
                m.stop_loss_order_amount,
                b.short_code,
                b.bet_class,
                b.buy_price,
                b.sell_price,
                b.payout_price,
                b.sell_time,
                b.purchase_time,
                b.is_sold,
                b.remark AS bet_remark,
                b.bet_class,
                COALESCE(p.remark, CASE WHEN t.action_type = 'escrow' THEN t.remark ELSE '' END) AS payment_remark
            FROM
                (
                    SELECT * FROM TRANSACTION.TRANSACTION
                    WHERE
                        account_id = $1
                        AND transaction_time < $2
                        AND transaction_time > $3
                        AND ($4 IS NULL OR id = $4)
                    ORDER BY transaction_time ##SORT_ORDER##
                    LIMIT $5
                ) t
                LEFT JOIN bet.financial_market_bet b
                    ON (t.financial_market_bet_id = b.id)
                LEFT JOIN payment.payment p
                    ON (t.payment_id = p.id)
                LEFT JOIN bet.multiplier m
                    ON (b.id = m.financial_market_bet_id)
                ORDER BY t.transaction_time DESC
        };

    #Reverse sort on transactions when only after is mentioned
    #      after => '2014-06-01'
    # should display the first 50 transactions after the date '2014-06-01'
    # not the last 50 transactions from today.
    my $sort_order = ($args->{after} and not $args->{before}) ? 'ASC' : 'DESC';
    $sql =~ s/##SORT_ORDER##/$sort_order/g;

    my $before = $args->{before} || Date::Utility->new()->plus_time_interval('1d')->datetime_yyyymmdd_hhmmss;
    my $after  = $args->{after}  || '1970-01-01 00:00:00';
    my $limit  = $args->{limit}  || 50;

    my $transaction_id = looks_like_number($args->{transaction_id}) ? $args->{transaction_id} : undef;

    my $dbic = $self->db->dbic;
    return $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);

            $sth->bind_param(1, $self->account->id);
            $sth->bind_param(2, $before);
            $sth->bind_param(3, $after);
            $sth->bind_param(4, $transaction_id);
            $sth->bind_param(5, $limit);

            my $transactions = [];
            if ($sth->execute()) {
                while (my $row = $sth->fetchrow_hashref()) {
                    $row->{date} = Date::Utility->new($row->{transaction_time});
                    push @$transactions, $row;
                }
            }
            return $transactions;
        });
}

sub get_bet_transactions_for_broker {
    my $self        = shift;
    my $arg         = shift;
    my $action_type = $arg->{'action_type'};
    my $broker_code = $arg->{'broker_code'};
    my $start       = $arg->{'start'};
    my $end         = $arg->{'end'};

    if ($action_type ne $BOM::Database::Model::Constants::BUY and $action_type ne $BOM::Database::Model::Constants::SELL) {
        Carp::croak("[get_bet_transactions_for_broker] wrong action type [$action_type]");
    }

    my $dbic = $self->db->dbic;

    my $sql = q{
        SELECT
            date_trunc('second' , t.transaction_time) as transaction_time,
            t.id,
            t.financial_market_bet_id as bet_id,
            a.client_loginid,
            t.quantity,
            a.currency_code,
            t.amount,
            b.short_code,
            t.financial_market_bet_id,
            c.residence,
            b.underlying_symbol

        FROM
            transaction.account a
            JOIN transaction.transaction t ON (a.id = t.account_id)
            JOIN betonmarkets.client c ON (a.client_loginid = c.loginid)
            LEFT JOIN bet.financial_market_bet b ON (b.id = t.financial_market_bet_id)

        WHERE
            c.broker_code = ?
            AND t.action_type = ?
            AND date_trunc('day', t.transaction_time) >= ?
            AND date_trunc('day', t.transaction_time) <= ?

        ORDER BY
            t.id
    };

    return $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute($broker_code, $action_type, $start, $end);
            return $sth->fetchall_hashref('id');
        });
}

sub get_details_by_transaction_ref {
    my $self           = shift;
    my $transaction_id = shift;
    my $sql            = q{
    SELECT
        a.client_loginid AS loginid,
        b.short_code AS shortcode,
        b.buy_price as ask_price,
        b.sell_price as bid_price,
        a.currency_code AS currency_code,
        t.action_type as action_type,
        d.price_slippage AS price_slippage,
        b.sell_time as sell_time,
        b.purchase_time as purchase_time,
        d.requested_price as order_price,
        d.spot as current_spot,
        d.iv as high_barrier_vol,
        d.iv_2 as low_barrier_vol,
        d.pricing_spot as pricing_spot,
        d.news_adjusted_pricing_vol as news_adjusted_pricing_vol,
        d.long_term_prediction as long_term_prediction,
        d.volatility_scaling_factor as volatility_scaling_factor,
        d.trading_period_start as trading_period_start
      FROM
        transaction.transaction t
        JOIN bet.financial_market_bet b ON t.financial_market_bet_id=b.id
        JOIN transaction.account a on a.id=t.account_id
        JOIN data_collection.quants_bet_variables d on d.transaction_id = t.id
    WHERE
        t.id = $1
   };

    return $self->db->dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute($transaction_id);

            return $sth->fetchall_arrayref({})->[0];
        });
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

 RMG Company

=cut
