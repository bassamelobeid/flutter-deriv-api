package BOM::Database::DataMapper::CollectorReporting;

=head1 NAME

BOM::Database::DataMapper::CollectorReporting

=head1 DESCRIPTION

This is a class that will collect report queries which run on collector-db.

=head1 VERSION

0.1

=cut

use Moose;
use Date::Utility;
extends 'BOM::Database::DataMapper::AccountBase';

=head1 METHODS

=over

=item get_open_bet_overviews($at_date)

Get partial information about all open bets at a given time.

=cut

sub get_open_bet_overviews {
    my $self        = shift;
    my $before_date = shift;

    my $last_generated = $self->get_last_generated_historical_marked_to_market_time;
    my $from_historical = ($last_generated and $before_date->is_before(Date::Utility->new($last_generated))) ? 1 : undef;

    my $sql;
    if ($from_historical) {
        $sql = q{ SELECT * FROM accounting.get_historical_open_bets_overview(?) };
    } else {
        $sql = q{ SELECT * FROM accounting.get_open_bets_overview() };
    }

    my $sth = $self->db->dbh->prepare($sql);
    if ($from_historical) {
        $sth->execute($before_date->db_timestamp);
    } else {
        $sth->execute;
    }

    return [values %{$sth->fetchall_hashref('id')}];
}

=item get_last_generated_historical_marked_to_market_time

Get the last calculation time of realtime_book. It is used in company pnl calculations.

=cut

sub get_last_generated_historical_marked_to_market_time {
    my $self = shift;
    my $dbh  = $self->db->dbh;

    my $sql = q{
        SELECT
            date_trunc('second', calculation_time) as max_time
        FROM
            accounting.historical_marked_to_market
        ORDER BY
            calculation_time DESC
        LIMIT 1
    };

    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my $result = $sth->fetchrow_hashref();
    if ($result) {
        return $result->{'max_time'};
    }
    return;
}

=item get_active_accounts_payment_profit({ start_time => $start_time, end_time => end_time})

Get payment & profit info for active accounts from $start_time to $end_time

=cut

sub get_active_accounts_payment_profit {
    my $self = shift;
    my $args = shift;

    my $sql = q{ SELECT * FROM accounting.get_active_accounts_payment_profit(?, ?) };
    my $sth = $self->db->dbh->prepare($sql);
    $sth->execute($args->{start_time}->db_timestamp, $args->{end_time}->db_timestamp);

    return values %{$sth->fetchall_hashref('account_id')};
}

sub turnover_in_period {
    my $self = shift;
    my $args = shift;

    my $dbh = $self->db->dbh;
    my $sql = q{ SELECT * FROM accounting.turnover_in_period(?, ?) };

    my $sth = $dbh->prepare($sql);
    $sth->execute($args->{start_date}, $args->{end_date});

    return $sth->fetchall_hashref('accid');
}

=item check_clients_duplication

return list of clients that open more than one accounts

=cut

sub check_clients_duplication {
    my $self      = shift;
    my $from_date = shift;
    my $dbh       = $self->db->dbh;

    my $sql = q{
        SELECT * FROM check_client_duplication(?)
    };

    my $sth = $dbh->prepare($sql);
    $sth->execute($from_date->datetime_yyyymmdd_hhmmss);

    return $sth->fetchall_arrayref({});
}

sub get_aggregated_sum_of_transactions_of_month {
    my $self            = shift;
    my $args            = shift;
    my $month_first_day = $args->{date};

    my $dbh = $self->db->dbh;
    my $sth = $dbh->prepare("SELECT * FROM sum_of_bet_txn_of_month(?)");
    $sth->execute($month_first_day);

    return $sth->fetchall_hashref([qw(date action_type currency_code)]);

}

=item number_of_active_clients_of_month

Returns the number of active clients for the month

=back
=cut

sub number_of_active_clients_of_month {
    my $self            = shift;
    my $month_first_day = shift;

    my $sql = q{ SELECT * FROM number_of_active_clients_of_month(?) };

    my $dbh = $self->db->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->execute($month_first_day);

    return $sth->fetchall_hashref('transaction_time');
}

sub get_clients_result_by_field {
    my $self = shift;
    my $args = shift;

    my $broker        = $args->{'broker'};
    my $field_arg_ref = $args->{'field_arg_ref'};

    my $sql = q{ SELECT * FROM accounting.get_clients_result_by_field(?, ?, ?, ?) };

    my $first_name = (exists $field_arg_ref->{first_name}) ? $field_arg_ref->{first_name} : '';
    my $last_name  = (exists $field_arg_ref->{last_name})  ? $field_arg_ref->{last_name}  : '';
    my $email      = (exists $field_arg_ref->{email})      ? $field_arg_ref->{email}      : '';

    my @binds = ('%' . $first_name . '%', '%' . $last_name . '%', '%' . $email . '%', '%' . $broker . '%');

    my $dbh = $self->db->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->execute(@binds);

    my $result = $sth->fetchall_arrayref({});
    return $result;
}

sub get_unregistered_client_token_pairs_before_datetime {
    my $self    = shift;
    my $to_date = shift;

    my $sql = q{ SELECT * FROM get_unregistered_client_token_pairs_before_datetime(?) };

    my $dbh = $self->db->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->execute($to_date);

    my $result = $sth->fetchall_arrayref({});
    return $result;
}

sub get_clients_with_unchecked_affiliate_exposures {
    my $self = shift;

    my $sql = q{
        SELECT t.*
        FROM
            betonmarkets.production_servers() s,
            dblink(s.srvname, $$

                SELECT
                    c.loginid,
                    count(*)
                FROM
                    (
                        SELECT
                            c.loginid,
                            count(*) as deposit_cnt
                        FROM
                            betonmarkets.client c,
                            transaction.account a,
                            payment.payment p
                        WHERE
                            c.loginid = a.client_loginid
                            AND a.id = p.account_id
                            AND a.is_default
                            AND c.checked_affiliate_exposures IS FALSE
                            AND p.amount > 0
                            AND p.payment_gateway_code NOT IN (
                                'free_gift',
                                'compacted_statement',
                                'cancellation',
                                'closed_account',
                                'miscellaneous',
                                'adjustment',
                                'affiliate_reward',
                                'payment_fee',
                                'virtual_credit',
                                'account_transfer',
                                'currency_conversion_transfer'
                            )
                        GROUP BY 1
                    ) c,
                    betonmarkets.client_affiliate_exposure e
                WHERE
                    c.loginid = e.client_loginid
                GROUP BY 1

            $$) t(
                loginid TEXT,
                count BIGINT
            )
        };

    my $dbh = $self->db->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my $result = $sth->fetchall_arrayref({});
    return $result;
}

no Moose;
__PACKAGE__->meta->make_immutable;

=head1 AUTHOR

RMG Company

=head1 COPYRIGHT

(c) 2014 RMG Technology (Malaysia) Sdn Bhd

=cut

1;
