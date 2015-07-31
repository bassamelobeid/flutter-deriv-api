package BOM::Database::DataMapper::FinancialMarketBet;

=head1 NAME

BOM::Database::DataMapper::FinancialMarketBet

=head1 DESCRIPTION

This is a class that will collect general financial_market_bet queries and is parent to other bet data mapper classes

=head1 VERSION

0.1

=cut

use Moose;
use Carp;
use BOM::Database::AutoGenerated::Rose::FinancialMarketBet::Manager;
use BOM::Database::Model::FinancialMarketBet;
use BOM::Database::Model::Constants;
use BOM::Database::Model::FinancialMarketBet::HigherLowerBet;
use BOM::Database::Model::FinancialMarketBet::SpreadBet;
use BOM::Database::Model::FinancialMarketBet::TouchBet;
use BOM::Database::Model::FinancialMarketBet::RangeBet;
use BOM::Database::Model::FinancialMarketBet::DigitBet;
use Date::Utility;
use BOM::Utility::CurrencyConverter qw(in_USD);
use Try::Tiny;

extends 'BOM::Database::DataMapper::AccountBase';

has '_mapper_model_class' => (
    is       => 'ro',
    isa      => 'Str',
    init_arg => undef,
    default  => 'BOM::Database::Model::FinancialMarketBet',
);

=head1 METHODS

=head2 get_turnover_of_client

get turnover for specific bet types or market for account

=cut

sub get_turnover_of_client {
    my $self = shift;
    my $args = shift;

    if (not $args) {
        Carp::croak("get_turnover_of_client - must pass in arguments");
    }

    my $dbh                  = $self->db->dbh;
    my $login_id             = $self->client_loginid;
    my $get_overall_turnover = $args->{'overall_turnover'};
    my $is_USD               = $args->{'convert_to_USD'};
    my $is_tick_expiry       = $args->{'tick_expiry'};

    # get the sum of buy price for all bets bought
    my $sql = q{
    SELECT
        SUM(buy_price) as turnover,
        currency_code as currency
    FROM
    bet.financial_market_bet b,
    transaction.account a
    WHERE
        b.account_id = a.id
        AND a.client_loginid = ?
    };

    if ($args->{'symbols'}) {
        my @symbols = @{$args->{'symbols'}};
        my $counter = 0;
        my $symbols_list;
        foreach my $symbol (@symbols) {
            if ($counter > 0) {
                $symbols_list .= ' OR ';
            }

            $symbols_list .= "b.underlying_symbol = '$symbol'";
            $counter++;
        }
        $sql .= ' AND (' . $symbols_list . ') ';

    }

    if (not $get_overall_turnover) {
        $sql .= ' AND b.purchase_time::DATE >= now()::DATE';
    }

    if ($is_tick_expiry) {
        $sql .= ' and b.tick_count is not null';
    }

    if ($args->{'bet_type'}) {
        my @bet_types = @{$args->{'bet_type'}};
        my $count     = 0;
        my $bet_join;
        foreach my $bey_type (@bet_types) {
            if ($count > 0) {
                $bet_join .= ' OR ';
            }

            $bet_join .= "b.bet_type LIKE '%$bey_type%'";
            $count++;
        }
        $sql .= ' AND (' . $bet_join . ') ';
    }

    $sql .= ' AND a.is_default = TRUE ';
    $sql .= ' GROUP BY currency_code';

    my $turnover = 0;
    try {
        local $dbh->{'RaiseError'} = 1;

        my $sth = $dbh->prepare($sql);
        $sth->execute($login_id);

        my $turnover_hashref = $sth->fetchrow_hashref;
        if ($turnover_hashref and $turnover_hashref->{'turnover'}) {
            $turnover = $turnover_hashref->{'turnover'};
            if ($is_USD) {
                my $currency = $turnover_hashref->{'currency'};
                $turnover = in_USD($turnover, $currency);
            }
        }
    }
    catch {
        Carp::croak("BOM::Database::DataMapper::FinancialMarketBet - get_turnover_of_client [$_]");
    };

    return $turnover;
}

=head2 get_bet_count_of_client

get bet count of client

=cut

sub get_bet_count_of_client {
    my $self = shift;

    my $fmb_count = BOM::Database::AutoGenerated::Rose::FinancialMarketBet::Manager->get_financial_market_bet_count(
        require_objects => ['account'],
        query           => [
            client_loginid => $self->client_loginid,
            is_default     => 1,
        ],
        group_by => ['client_loginid',],
        db       => $self->db,
    );
    return $fmb_count;
}

=head2 get_number_of_open_bets_with_shortcode_of_account

get number of open bets with shortcode, for an account

=cut

sub get_number_of_open_bets_with_shortcode_of_account {
    my $self       = shift;
    my $short_code = shift;

    my $open_bets_count = BOM::Database::AutoGenerated::Rose::FinancialMarketBet::Manager->get_financial_market_bet_count(
        require_objects => ['account'],
        query           => [
            't2.client_loginid' => $self->client_loginid,
            't2.currency_code'  => $self->currency_code,
            't1.short_code'     => $short_code,
            't1.is_sold'        => 0,
        ],
        db => $self->db,
    );

    return $open_bets_count;
}

sub get_open_bets_of_account {
    my $self = shift;

    my $sql = q{
        SELECT fmb.*, t.id buy_id
        FROM
            bet.financial_market_bet fmb
            JOIN transaction.transaction t on (action_type='buy' and t.financial_market_bet_id=fmb.id)
        WHERE
            fmb.account_id = ?
            AND is_sold = false
        ORDER BY
            expiry_time
    };

    my $sth = $self->db->dbh->prepare($sql);
    $sth->execute($self->account->id);

    return $sth->fetchall_arrayref({});
}

sub get_fmbs_by_loginid_and_currency {
    my $self = shift;
    my $args = shift;


    my $sql = <<'SQL';
SELECT b.*
  FROM bet.financial_market_bet b
  JOIN transaction.account a ON a.id=b.account_id
 WHERE a.client_loginid=$1
   AND a.currency_code=$2
SQL

    $sql .= "   AND NOT b.is_sold\n"         if $args->{exclude_sold};
    $sql .= "   AND b.expiry_time < now()\n" if $args->{only_expired};

    my $sth = $self->db->dbh->prepare($sql);
    $sth->execute($self->client_loginid, $self->currency_code);

    return $sth->fetchall_arrayref({});
}

=head2 get_fmb_by_id

Get bets by id (it can be an ARRAYREF of financial_market_bet_id)

=cut

sub get_fmb_by_id {
    my $self = shift;
    my $bet_ids = shift || Carp::croak('Invalid bet_ids reference');
    Carp::croak('Only array ref accepted as $bet_ids') if ref $bet_ids ne 'ARRAY';
    my $return_hash = shift || undef;

    my $bets = BOM::Database::AutoGenerated::Rose::FinancialMarketBet::Manager->get_financial_market_bet(
        require_objects => ['account'],
        with_objects    => [
            $BOM::Database::Model::Constants::BET_CLASS_HIGHER_LOWER_BET, $BOM::Database::Model::Constants::BET_CLASS_RANGE_BET,
            $BOM::Database::Model::Constants::BET_CLASS_TOUCH_BET,        $BOM::Database::Model::Constants::BET_CLASS_LEGACY_BET,
            $BOM::Database::Model::Constants::BET_CLASS_DIGIT_BET,
        ],
        query => [id => $bet_ids],
        db    => $self->db,
        debug => $self->debug,
    );

    return if scalar @{$bets} == 0;

    if ($return_hash) {
        my %bet_models = map { $_->id => $self->_fmb_rose_to_fmb_model($_) } @{$bets};
        return \%bet_models;
    } else {
        my @bet_models = map { $self->_fmb_rose_to_fmb_model($_) } @{$bets};
        return \@bet_models;
    }
}

sub get_fmb_by_shortcode {
    my $self = shift;
    my $short_code = shift || Carp::croak('Invalid short_code');

    my $bets = BOM::Database::AutoGenerated::Rose::FinancialMarketBet::Manager->get_financial_market_bet(
        require_objects => ['account'],
        with_objects    => [
            $BOM::Database::Model::Constants::BET_CLASS_HIGHER_LOWER_BET, $BOM::Database::Model::Constants::BET_CLASS_RANGE_BET,
            $BOM::Database::Model::Constants::BET_CLASS_TOUCH_BET,        $BOM::Database::Model::Constants::BET_CLASS_LEGACY_BET,
            $BOM::Database::Model::Constants::BET_CLASS_DIGIT_BET,
        ],
        query => [
            short_code => $short_code,
            account_id => $self->account->id
        ],
        db    => $self->db,
        debug => $self->debug,
    );

    return if scalar @{$bets} == 0;

    my @bet_models = map { $self->_fmb_rose_to_fmb_model($_) } @{$bets};
    return \@bet_models;
}

=head2 get_sold(%args)

Returns list of sold bets for the specified intervals.
Returns the bets in the order of purchase date.

Accepts the following arguments:

=over

=item B<before>

Bets purchased before this date. Defaults to tomorrow.

=item B<after>

Bets purchased after this date. Defaults to 1970-01-01 00:00:00.

=item B<limit>

Number of bets to list. Defaults to 50.

=back

=cut

sub get_sold {
    my ($self, $args) = @_;

    #Nested query is required to be able to independantly choose the selection order when only after is mentioned(see below).
    #When only after is mentioned we sort ASC and apply the limit over that.
    #No matter what the sort order was chosen for applying the limit the output should always be sorted DESC.
    #We could potentially break this into 2/3 queries but this solution looks clearer.

    #Reverse sort on fmb when only after is mentioned
    #      after => '2014-06-01'
    # should get us the first 50 contracts after the date '2014-06-01'
    # not the last 50 contracts from today.
    my $sort_order = ($args->{after} and not $args->{before}) ? 'ASC' : 'DESC';

    my $sql = q{
            SELECT
                t.id as txn_id,
                b.*
            FROM
                (
                    SELECT
                        *
                    FROM
                        bet.financial_market_bet
                    WHERE
                        account_id = $1
                        AND is_sold = true
                        AND purchase_time < $2
                        AND purchase_time > $3
                    ORDER BY purchase_time } . $sort_order . q{
                    LIMIT $4
                ) b,
                transaction.transaction t
            WHERE
                t.financial_market_bet_id = b.id
                AND t.action_type = 'buy'
            ORDER BY b.purchase_time DESC
        };

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
            $row->{purchase_date} = Date::Utility->new($row->{purchase_time});
            $row->{sale_date}     = Date::Utility->new($row->{sell_time});
            push @$transactions, $row;
        }
    }
    return $transactions;
}

###
# PRIVATE: convertor of rose to model
sub _fmb_rose_to_fmb_model {
    my $self        = shift;
    my $rose_object = shift;

    my $model_class;
    my $param = {'financial_market_bet_record' => $rose_object};
    $param->{'db'} = $self->db;

    if ($rose_object->bet_class eq $BOM::Database::Model::Constants::BET_CLASS_HIGHER_LOWER_BET) {
        $param->{'higher_lower_bet_record'} = $rose_object->higher_lower_bet;
        $model_class = 'BOM::Database::Model::FinancialMarketBet::HigherLowerBet';
    } elsif ($rose_object->bet_class eq $BOM::Database::Model::Constants::BET_CLASS_DIGIT_BET) {
        $param->{'digit_bet_record'} = $rose_object->digit_bet;
        $model_class = 'BOM::Database::Model::FinancialMarketBet::DigitBet';
    } elsif ($rose_object->bet_class eq $BOM::Database::Model::Constants::BET_CLASS_RANGE_BET) {
        $param->{'range_bet_record'} = $rose_object->range_bet;
        $model_class = 'BOM::Database::Model::FinancialMarketBet::RangeBet';
    } elsif ($rose_object->bet_class eq $BOM::Database::Model::Constants::BET_CLASS_TOUCH_BET) {
        $param->{'touch_bet_record'} = $rose_object->touch_bet;
        $model_class = 'BOM::Database::Model::FinancialMarketBet::TouchBet';
    } elsif ($rose_object->bet_class eq $BOM::Database::Model::Constants::BET_CLASS_LEGACY_BET) {
        $param->{'legacy_bet_record'} = $rose_object->legacy_bet;
        $model_class = 'BOM::Database::Model::FinancialMarketBet::LegacyBet';
    } elsif ($rose_object->bet_class eq $BOM::Database::Model::Constants::BET_CLASS_SPREAD_BET) {
        $param->{'spread_bet_record'} = $rose_object->spread_bet;
        $model_class = 'BOM::Database::Model::FinancialMarketBet::SpreadBet';
    } else {
        Carp::croak('UNSUPPORTED rose_object class [' . $rose_object->bet_class . ']');
    }

    return $model_class->new($param);
}

sub get_bet_turnover_and_payout_for_all_currencies {
    my $self = shift;
    my $args = shift;

    if (not $args or not $args->{'bet_type'} or not $args->{'days_ago'}) {
        Carp::croak("get_bet_turnover_and_payout_for_all_currencies - must pass in bet_type and days_ago ");
    }

    # get the sum of buy price for all bets bought
    my $sql = q{
    SELECT
    SUM(data_collection.exchangetousd(buy_price, currency_code, purchase_time)) as turnover,
    SUM(data_collection.exchangetousd(payout_price, currency_code, purchase_time)) as payout
    FROM
    bet.financial_market_bet b,
    transaction.account a
    WHERE
    b.account_id = a.id
        AND bet_type = ?
        AND purchase_time > NOW() - ?::interval
        AND client_loginid = ?
    };
    my @sql_bind = ($args->{'bet_type'}, $args->{'days_ago'} . ' day', $self->client_loginid);

    if ($args->{'underlying_symbol'}) {
        $sql .= ' AND underlying_symbol= ? ';
        push @sql_bind, $args->{'underlying_symbol'};
    }

    my $dbh = $self->db->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->execute(@sql_bind);

    my $result;
    $result = $sth->fetchrow_hashref;
    my $turnover = $result->{'turnover'} || 0;
    my $payout   = $result->{'payout'}   || 0;
    return {
        turnover => $turnover,
        payout   => $payout,
    };

}

no Moose;
__PACKAGE__->meta->make_immutable;

=head1 AUTHOR

RMG Company

=head1 COPYRIGHT

(c) 2011 RMG Technology (Malaysia) Sdn Bhd

=cut

1;
