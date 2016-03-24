package BOM::Database::DataMapper::Transaction;

=head1 NAME

BOM::Database::DataMapper::Transaction

=head1 DESCRIPTION

This is a class that will collect general transaction queries.

=head1 VERSION

0.1

=cut

use Moose;
use BOM::Database::AutoGenerated::Rose::Transaction::Manager;
use BOM::Database::AutoGenerated::Rose::Account::Manager;
use BOM::Database::Model::Constants;
use BOM::Database::Model::Transaction;
use BOM::Database::Model::Constants;
use Date::Utility;
use Try::Tiny;
use Carp;
extends 'BOM::Database::DataMapper::AccountBase';

has '_mapper_model_class' => (
    is       => 'ro',
    isa      => 'Str',
    init_arg => undef,
    default  => 'BOM::Database::Model::Transaction',
);

=head2 C<< $self->get_balance_after_transaction(+{transaction_time=>$timestamp}) >>

Returns account balance after the transaction. Just before or at a given point in
time.

Accepts following parameters:

=over 4

=item transaction_time

the time as postgres compatible string.

=back

=cut

sub get_balance_after_transaction {
    my ($self, $args) = @_;

    my $account_id = $self->account->id;
    unless ($args->{transaction_time}) {
        croak "Must pass transaction_time argument" unless $args->{transaction_time};
    }

    # our natural query here would be:
    #
    # SELECT round(balance_after, 2)
    #   FROM transaction.transaction
    #  WHERE account_id=$1
    #    AND transaction_time<=$2
    #  ORDER BY transaction_time DESC, id DESC
    #  LIMIT 1
    #
    # there is an index: transaction_acc_id_txn_time_desc_idx
    #                        btree (account_id, transaction_time DESC)
    #
    # Unfortunately, the index cannot be used because of the additional
    # ordering on "id". Alternative plans based on our current indexes
    # always construct and sort the complete list of transactions for
    # the account. However, we can prevent this by first fetching the
    # timestamp of the most recent transaction before the given timestamp.
    # Then we can use it to fetch all rows with that timestamp. This
    # query will then use the index above.
    #
    # An alternative to this approach is to modify the index. One could
    # drop that index and replace it with:
    #
    #     transaction_acc_id_txn_time_desc_id_desc_idx
    #         btree (account_id, transaction_time DESC, id DESC)
    #
    # This index would require more space and first we had to create
    # it which is slightly complicated on transaction in CR and VR.

    # Once all the balance_after column is up-to-date for all accounts
    # we can get rid of the coalesce-part.
    my $sql = <<'SQL';
SELECT round(coalesce(balance_after, (SELECT sum(amount)
                                        FROM transaction.transaction
                                       WHERE account_id=$1
                                         AND transaction_time<=$2)), 2)
  FROM transaction.transaction
 WHERE account_id=$1
   AND transaction_time=(SELECT max(transaction_time)
                           FROM transaction.transaction
                          WHERE account_id=$1
                            AND transaction_time<=$2)
 ORDER BY id DESC
 LIMIT 1
SQL

    my ($balance) = $self->db->dbh->selectrow_array($sql, {}, $account_id, $args->{transaction_time});

    return $balance;
}

sub get_daily_summary_report {
    my $self = shift;
    my $args = shift;

    my $start_of_next_day = $args->{'start_of_next_day'};
    my $broker_code       = $args->{'broker_code'};
    my $currency_code     = $args->{'currency_code'};

    my $dbh = $self->db->dbh;

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
                payment_time < $3::date
            GROUP BY
                account_id
        ) payment_table ON (payment_table.account_id=a.id)

        WHERE
                a.currency_code= $1
                AND substring(client_loginid from $2)<>''
        ORDER BY
            a.id
    };

    my $sth = $dbh->prepare($sql);

    $sth->bind_param(1, $currency_code);
    $sth->bind_param(2, '^' . $broker_code . '[0-9]+');
    $sth->bind_param(3, $start_of_next_day);

    $sth->execute();

    return $sth->fetchall_hashref('loginid');
}

sub get_accounts_with_open_bets_at_end_of {
    my $self = shift;
    my $args = shift;

    my $start_of_next_day = $args->{'start_of_next_day'};
    my $broker_code       = $args->{'broker_code'};
    my $currency_code     = $args->{'currency_code'};

    my $dbh = $self->db->dbh;

    my $sql = <<'SQL';
SELECT b.*
  FROM (
     SELECT *
       FROM bet.financial_market_bet
      WHERE is_sold IS FALSE
        AND bet_class NOT IN ('legacy_bet', 'run_bet')
        AND purchase_time < $3::TIMESTAMP

      UNION ALL

     SELECT *
       FROM bet.financial_market_bet
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

    my $sth = $dbh->prepare($sql);

    $sth->bind_param(1, $currency_code);
    $sth->bind_param(2, $broker_code);
    $sth->bind_param(3, $start_of_next_day);

    $sth->execute();
    my $open_bets = $sth->fetchall_hashref('id');

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

    my $dbh = $self->db->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->execute($self->client_loginid, $self->currency_code);

    if (my $transaction_hashref = $sth->fetchrow_hashref) {
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
    my $dbh        = $self->db->dbh;

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

    my $sth = $dbh->prepare($sql);
    $sth->execute($self->client_loginid, $start_time->db_timestamp);

    return $sth->fetchall_arrayref({});
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
            p.remark AS payment_remark
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

    my $dbh = $self->db->dbh;
    my $sth = $dbh->prepare($sql);

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
}

sub get_transactions_ws {
    my ($self, $args, $acc) = @_;

    my $sql = q{
            SELECT
                t.*,
                b.short_code,
                b.purchase_time,
                b.sell_time,
                p.payment_time,
                p.remark AS payment_remark
            FROM
                (
                    SELECT * FROM transaction.transaction
                    WHERE
                        account_id = ?
                        AND transaction_time < ?
                        AND transaction_time >= ?
                        ##ACTION_TYPE##
                    ORDER BY transaction_time DESC
                    LIMIT ?
                    OFFSET ?
                ) t
                LEFT JOIN bet.financial_market_bet b
                    ON (t.financial_market_bet_id = b.id)
                LEFT JOIN payment.payment p
                    ON (t.payment_id = p.id)
                ORDER BY t.transaction_time DESC
    };

    my $limit  = $args->{limit}  || 100;
    my $offset = $args->{offset} || 0;
    my $dt_fm  = $args->{date_from};
    my $dt_to  = $args->{date_to};

    for ($dt_fm, $dt_to) {
        $_ = eval { Date::Utility->new($_)->datetime } if ($_);
    }
    $dt_fm ||= '1970-01-01';
    $dt_to ||= Date::Utility->today->plus_time_interval('1d')->datetime;

    my $action_type = ($args->{action_type}) ? 'AND action_type = ?' : '';
    $sql =~ s/##ACTION_TYPE##/$action_type/;

    my @binds = ($acc->id, $dt_to, $dt_fm, ($action_type) ? $action_type : (), $limit, $offset);
    return $self->db->dbh->selectall_arrayref($sql, {Slice => {}}, @binds);
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
                b.short_code,
                b.bet_class,
                b.buy_price,
                b.sell_price,
                b.payout_price,
                b.sell_time,
                b.purchase_time,
                b.is_sold,
                b.remark AS bet_remark,
                p.remark AS payment_remark
            FROM
                (
                    SELECT * FROM TRANSACTION.TRANSACTION
                    WHERE
                        account_id = $1
                        AND transaction_time < $2
                        AND transaction_time > $3
                    ORDER BY transaction_time ##SORT_ORDER##
                    LIMIT $4
                ) t
                LEFT JOIN bet.financial_market_bet b
                    ON (t.financial_market_bet_id = b.id)
                LEFT JOIN payment.payment p
                    ON (t.payment_id = p.id)
                ORDER BY t.transaction_time DESC
        };

    #Reverse sort on transactions when only after is mentioned
    #      after => '2014-06-01'
    # should display the first 50 transactions after the date '2014-06-01'
    # not the last 50 transcations from today.
    my $sort_order = ($args->{after} and not $args->{before}) ? 'ASC' : 'DESC';
    $sql =~ s/##SORT_ORDER##/$sort_order/g;

    my $before = $args->{before} || Date::Utility->new()->plus_time_interval('1d')->datetime_yyyymmdd_hhmmss;
    my $after  = $args->{after}  || '1970-01-01 00:00:00';
    my $limit  = $args->{limit}  || 50;

    my $dbh = $self->db->dbh;
    my $sth = $dbh->prepare($sql);

    $sth->bind_param(1, $self->account->id);
    $sth->bind_param(2, $before);
    $sth->bind_param(3, $after);
    $sth->bind_param(4, $limit);

    my $transactions = [];
    if ($sth->execute()) {
        while (my $row = $sth->fetchrow_hashref()) {
            $row->{date} = Date::Utility->new($row->{transaction_time});
            push @$transactions, $row;
        }
    }
    return $transactions;
}

=head2 get_transaction_before($date)

Returns a single transaction before the specified date.

=cut

sub get_transaction_before {
    my $self = shift;
    my $before = shift || Date::Utility->new()->datetime_yyyymmdd_hhmmss;

    my $sql = q{
                SELECT * FROM TRANSACTION.TRANSACTION
                WHERE
                    account_id = $1
                    AND transaction_time < $2
                ORDER BY transaction_time DESC
                LIMIT 1
        };

    my $dbh = $self->db->dbh;
    my $sth = $dbh->prepare($sql);

    $sth->bind_param(1, $self->account->id);
    $sth->bind_param(2, $before);

    $sth->execute();
    return $sth->fetchall_hashref('id');
}

=head2 get_transaction_after($date)

Returns a single transaction after the specified date.

=cut

sub get_transaction_after {
    my $self = shift;
    my $after = shift || '1970-01-01 00:00:00';

    my $sql = q{
                SELECT * FROM TRANSACTION.TRANSACTION
                WHERE
                    account_id = $1
                    AND transaction_time > $2
                ORDER BY transaction_time DESC
                LIMIT 1
        };

    my $dbh = $self->db->dbh;
    my $sth = $dbh->prepare($sql);

    $sth->bind_param(1, $self->account->id);
    $sth->bind_param(2, $after);

    $sth->execute();
    return $sth->fetchall_hashref('id');
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

    my $dbh = $self->db->dbh;

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

    my $sth = $dbh->prepare($sql);
    $sth->execute($broker_code, $action_type, $start, $end);
    my $result = $sth->fetchall_hashref('id');

    return $result;
}

sub get_profit_for_days {
    my ($self, $args) = @_;

    my $before = $args->{before} || Date::Utility->new()->datetime_yyyymmdd_hhmmss;
    my $after  = $args->{after}  || '1970-01-01 00:00:00';

    my $sql = q{
            SELECT
                sum(amount)
            FROM
                TRANSACTION.TRANSACTION
            WHERE
                account_id = $1
                AND transaction_time <= $2
                AND transaction_time > $3
                AND action_type IN ('buy', 'sell')
        };

    my $dbh = $self->db->dbh;
    my $sth = $dbh->prepare($sql);

    $sth->bind_param(1, $self->account->id);
    $sth->bind_param(2, $before);
    $sth->bind_param(3, $after);

    $sth->execute();
    my $result = $sth->fetchrow_arrayref() || [0];
    return $result->[0];
}

sub get_details_by_transaction_ref {
    my $self           = shift;
    my $transaction_id = shift;
    my $sql            = q{
    SELECT 
    a.client_loginid AS loginid,
    b.short_code AS shortcode,
    a.currency_code AS currency_code
    FROM bet.financial_market_bet b
    LEFT JOIN transaction.transaction t ON t.financial_market_bet_id=b.id
    LEFT JOIN transaction.account a on a.id=b.account_id
    where t.id = $1
    };

    my $sth = $self->db->dbh->prepare($sql);
    $sth->execute($transaction_id);

    return $sth->fetchall_arrayref({})->[0];
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

 RMG Company

=cut
