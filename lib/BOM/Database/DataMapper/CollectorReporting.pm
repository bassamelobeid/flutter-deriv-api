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
        $sql = q{ SELECT * FROM accounting.get_historical_open_bets_overview_v2(?) };
    } else {
        $sql = q{ SELECT * FROM accounting.get_open_bets_overview() };
    }

    return $self->db->dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            if ($from_historical) {
                $sth->execute($before_date->db_timestamp);
            } else {
                $sth->execute;
            }

            return [values %{$sth->fetchall_hashref('id')}];
        });

}

=item get_last_generated_historical_marked_to_market_time

Get the last calculation time of realtime_book. It is used in company pnl calculations.

=cut

sub get_last_generated_historical_marked_to_market_time {
    my $self = shift;
    my $dbic = $self->db->dbic;

    my $result = $dbic->run(
        fixup => sub {
            my $sql = q{
        SELECT
            date_trunc('second', calculation_time) as max_time
        FROM
            accounting.historical_marked_to_market
        ORDER BY
            calculation_time DESC
        LIMIT 1
    };

            my $sth = $_->prepare($sql);
            $sth->execute();
            return $sth->fetchrow_hashref();
        });
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

    my $result = $self->db->dbic->run(
        fixup => sub {
            return $_->selectall_arrayref(
                q{ SELECT * FROM accounting.get_active_accounts_payment_profit_v2(?, ?) },
                {Slice => {}},
                $args->{start_time}->db_timestamp,
                $args->{end_time}->db_timestamp
            );
        });
    return @$result;
}

sub turnover_in_period {
    my $self = shift;
    my $args = shift;

    my $dbic = $self->db->dbic;
    my $sql  = q{ SELECT * FROM accounting.turnover_in_period_v2(?, ?) };

    return $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute($args->{start_date}, $args->{end_date});

            return $sth->fetchall_hashref('accid');
        });
}

=item check_clients_duplication

return list of clients that open more than one accounts

=cut

sub check_clients_duplication {
    my $self      = shift;
    my $from_date = shift;
    my $dbic      = $self->db->dbic;

    my $sql = q{
        SELECT new_loginid, first_name, last_name, date_of_birth, loginids FROM check_client_duplication($1)
        UNION
        SELECT new_loginid, first_name, last_name, date_of_birth, loginids FROM check_phone_duplication($1)
    };
    return $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute($from_date->datetime_yyyymmdd_hhmmss);

            return $sth->fetchall_arrayref({});
        });
}

sub get_aggregated_sum_of_transactions_of_month {
    my $self            = shift;
    my $args            = shift;
    my $month_first_day = $args->{date};

    my $dbic = $self->db->dbic;
    return $dbic->run(
        fixup => sub {
            my $sth = $_->prepare("SELECT * FROM sum_of_bet_txn_of_month(?)");
            $sth->execute($month_first_day);

            return $sth->fetchall_hashref([qw(date action_type currency_code)]);
        });

}

=item eod_market_values_of_month

get market value for each end of day, for period of 1 month
return hashref

=cut

sub eod_market_values_of_month {
    my $self            = shift;
    my $month_first_day = shift;
    my $dbic            = $self->db->dbic;

    return $dbic->run(
        fixup => sub {
            my $sth = $_->prepare(q{SELECT * FROM get_last_market_value_of_day(?)});
            $sth->execute($month_first_day);
            return $sth->fetchall_hashref('calculation_time');

        });
}

=item number_of_active_clients_of_month

Returns the number of active clients for the month

=back

=cut

sub number_of_active_clients_of_month {
    my $self            = shift;
    my $month_first_day = shift;

    my $sql = q{ SELECT * FROM number_of_active_clients_of_month(?) };

    my $dbic = $self->db->dbic;
    return $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute($month_first_day);
            return $sth->fetchall_hashref('transaction_time');
        });
}

sub get_clients_result_by_field {
    my $self = shift;
    my $args = shift;
    my @binds;
    my $sql = q{ SELECT * FROM accounting.get_clients_result_by_field(?, ?, ?, ?, ?, ?::date) };

    push @binds, map { '%' . ($args->{$_} // '') . '%' } (qw/first_name last_name email broker phone/);
    push @binds, $args->{date_of_birth};

    my $dbic = $self->db->dbic;
    return $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute(@binds);

            my $result = $sth->fetchall_arrayref({});
            return $result;
        });
}

sub get_unregistered_client_token_pairs_before_datetime {
    my $self    = shift;
    my $to_date = shift;

    my $sql = q{ SELECT * FROM get_unregistered_client_token_pairs_before_datetime(?) };

    my $dbic = $self->db->dbic;
    return $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute($to_date);

            my $result = $sth->fetchall_arrayref({});
            return $result;
        });
}

sub get_aggregate_balance_per_currency {
    my $self = shift;

    my $sql = q{ SELECT * FROM get_aggregate_balance_per_currency() };

    my $dbic = $self->db->dbic;
    return $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute();

            my $result = $sth->fetchall_arrayref({});
            return $result;
        });
}

no Moose;
__PACKAGE__->meta->make_immutable;

=head1 AUTHOR

RMG Company

=head1 COPYRIGHT

(c) 2014 RMG Technology (Malaysia) Sdn Bhd

=cut

1;
