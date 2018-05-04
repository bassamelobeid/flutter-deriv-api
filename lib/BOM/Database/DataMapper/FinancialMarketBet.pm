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
use BOM::Database::Model::FinancialMarketBet::LookbackOption;
use BOM::Database::Model::FinancialMarketBet::ResetBet;
use BOM::Database::Model::FinancialMarketBet::HighLowTick;
use Date::Utility;
use Try::Tiny;

extends 'BOM::Database::DataMapper::AccountBase';

has '_mapper_model_class' => (
    is       => 'ro',
    isa      => 'Str',
    init_arg => undef,
    default  => 'BOM::Database::Model::FinancialMarketBet',
);

sub get_sold_bets_of_account {
    my ($self, $args) = @_;

    my $limit = int($args->{limit} // 50);
    $limit = 50 unless $limit > 0 and $limit <= 50;
    my $offset = int($args->{offset} // 0);
    my $sort_dir = (($args->{sort} // '') eq 'ASC') ? 'ASC' : 'DESC';
    my $before   = $args->{before};
    my $after    = $args->{after};

    my $sql = q{
        FROM
            bet.financial_market_bet fmb
            JOIN transaction.transaction t on (action_type='buy' and t.financial_market_bet_id=fmb.id)
        WHERE
            fmb.account_id = ?
            AND is_sold = true
    };
    my @binds = ($self->account->id);
    if ($before and $before = try { Date::Utility->new($before) }) {
        $sql .= ' AND purchase_time < ?';
        ## If we were passed in a date (but not an epoch or full timestamp)
        ## add in one day, so that 2018-04-07 grabs the entire day by doing
        ## a "purchase_time < 2018-04-08 00:00:000'
        if (    $args->{before} =~ /\-/
            and $args->{before} !~ / /
            and $before->time_hhmmss eq '00:00:00')
        {
            $before = $before->plus_time_interval('1d');
        }
        push @binds, $before->datetime_yyyymmdd_hhmmss;
    }
    if ($after and $after = try { Date::Utility->new($after) }) {
        $sql .= ' AND purchase_time >= ?';
        push @binds, $after->datetime_yyyymmdd_hhmmss;
    }

    my $dbic = $self->db->dbic;
    return $dbic->run(
        fixup => sub {
            my $sth = $_->prepare("
        SELECT fmb.*, t.id txn_id, t.source
        $sql
        ORDER BY fmb.purchase_time $sort_dir, fmb.id $sort_dir
        LIMIT ? OFFSET ?
    ");
            $sth->execute(@binds, $limit, $offset);

            return $sth->fetchall_arrayref({});
        });
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
            $BOM::Database::Model::Constants::BET_CLASS_DIGIT_BET,        $BOM::Database::Model::Constants::BET_CLASS_LOOKBACK_OPTION,
            $BOM::Database::Model::Constants::BET_CLASS_RESET_BET,        $BOM::Database::Model::Constants::BET_CLASS_HIGH_LOW_TICK,
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

    my $dbic = $self->db->dbic;
    return $dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);

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
        });
}

# we need to get buy sell transactions id for particular contract
sub get_contract_details_with_transaction_ids {
    my $self        = shift;
    my $contract_id = shift;

    my $sql = q{
        SELECT fmb.*, t.id as transaction_id, t.action_type, t.app_markup
        FROM
            bet.financial_market_bet fmb
            JOIN transaction.transaction t on t.financial_market_bet_id=fmb.id
        WHERE
            fmb.id = ?
    };

    my @fmbs = $self->db->dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute($contract_id);
            return @{$sth->fetchall_arrayref({})};

        });
    my $response = [];

    if (scalar @fmbs > 0) {
        # get only first record as all other fields are similar
        my $record = $fmbs[0];

        foreach my $fmb (@fmbs) {
            if ($fmb->{action_type} eq 'buy') {
                $record->{buy_transaction_id} = $fmb->{transaction_id};
            } elsif ($fmb->{action_type} eq 'sell') {
                $record->{sell_transaction_id} = $fmb->{transaction_id};
            }
        }

        # delete these as we don't want to send it
        delete $record->{transaction_id};
        delete $record->{action_type};

        push @$response, $record;
    }

    return $response;
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
    } elsif ($rose_object->bet_class eq $BOM::Database::Model::Constants::BET_CLASS_LOOKBACK_OPTION) {
        $param->{'lookback_option_record'} = $rose_object->lookback_option;
        $model_class = 'BOM::Database::Model::FinancialMarketBet::LookbackOption';
    } elsif ($rose_object->bet_class eq $BOM::Database::Model::Constants::BET_CLASS_RESET_BET) {
        $param->{'reset_bet_record'} = $rose_object->reset_bet;
        $model_class = 'BOM::Database::Model::FinancialMarketBet::ResetBet';
    } elsif ($rose_object->bet_class eq $BOM::Database::Model::Constants::BET_CLASS_HIGH_LOW_TICK) {
        $param->{'highlowticks_record'} = $rose_object->highlowticks;
        $model_class = 'BOM::Database::Model::FinancialMarketBet::HighLowTick';
    } else {
        Carp::croak('UNSUPPORTED rose_object class [' . $rose_object->bet_class . ']');
    }

    return $model_class->new($param);
}

no Moose;
__PACKAGE__->meta->make_immutable;

=head1 AUTHOR

RMG Company

=head1 COPYRIGHT

(c) 2011 RMG Technology (Malaysia) Sdn Bhd

=cut

1;
