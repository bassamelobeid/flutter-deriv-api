package BOM::Database::Helper::FinancialMarketBet;

use Moose;
use BOM::Database::AutoGenerated::Rose::FinancialMarketBet;
use BOM::Database::AutoGenerated::Rose::QuantsBetVariable;
use BOM::Database::Model::DataCollection::QuantsBetVariables;
use Rose::DB;
use JSON::MaybeXS ();
use Carp;

has 'account_data' => (
    is  => 'rw',
    isa => 'HashRef|ArrayRef',
);

# this will end up being either a BOM::Database::Model::FinancialMarketBetOpen or a BOM::Database::Model::FinancialMarketBet
has 'bet' => (
    is => 'rw',
);

has 'bet_data' => (
    is         => 'rw',
    isa        => 'HashRef|ArrayRef',
    lazy_build => 1,
);

has 'transaction_data' => (
    is         => 'rw',
    isa        => 'Maybe[HashRef|ArrayRef]',
    lazy_build => 1,
);

has 'limits' => (
    is  => 'rw',
    isa => 'Maybe[HashRef|ArrayRef]',
);

has 'db' => (
    is  => 'rw',
    isa => 'Rose::DB',
);

has 'quants_bet_variables' => (
    is      => 'rw',
    isa     => 'Maybe[BOM::Database::Model::DataCollection::QuantsBetVariables|ArrayRef[BOM::Database::Model::DataCollection::QuantsBetVariables]]',
    default => undef,
);

my $json = JSON::MaybeXS->new;

sub _build_bet_data {
    my $self = shift;

    my $bd = $self->bet;

    croak "Please specify either bet_data or bet" unless $bd;

    my @fmb_col = BOM::Database::AutoGenerated::Rose::FinancialMarketBet->meta->columns;
    my @chld_col;
    # if you just want to sell a bet that you don't know the exact type,
    # you can pass it in as BOM::Database::Model::FinancialMarketBet
    unless (ref $bd eq 'BOM::Database::Model::FinancialMarketBet' || ref $bd eq 'BOM::Database::Model::FinancialMarketBetOpen') {
        @chld_col = BOM::Database::AutoGenerated::Rose::FinancialMarketBet->meta->{relationships}->{$bd->bet_class}->class->meta->columns;
    }

    my %bet = map {
        my $v = $bd->$_;
        $_ => eval { $v->can('db_timestamp') } ? $v->db_timestamp : defined $v ? "$v" : undef;
    } @fmb_col, @chld_col;
    return \%bet;
}

sub _build_transaction_data {
    my $self = shift;

    my $bd;
    if ($bd = $self->bet) {
        return $bd->legacy_parameters;
    } elsif ($bd = $self->bet_data and ref($bd) eq 'HASH') {
        return +{
            transaction_time => $bd->{transaction_time},
            staff_loginid    => $bd->{staff_loginid},
        };
    }

    return;
}

sub buy_bet {
    my $self = shift;

    my %bet = (
        expiry_daily => 0,
        is_expired   => 0,
        is_sold      => 0,
        %{$self->bet_data},
    );

    my @chld_col = BOM::Database::AutoGenerated::Rose::FinancialMarketBet->meta->{relationships}->{$bet{bet_class}}->class->meta->columns;
    my $qv       = $self->quants_bet_variables;
    my @qv_col   = BOM::Database::AutoGenerated::Rose::QuantsBetVariable->meta->columns;
    my $limits   = $self->limits;

    my @param = (
        # FMB stuff
        @{$self->account_data}{qw/client_loginid currency_code/},
        @bet{
            qw/purchase_time underlying_symbol
                payout_price buy_price start_time expiry_time
                settlement_time expiry_daily bet_class bet_type
                remark short_code fixed_expiry tick_count/
        },

        # FMB child table
        $json->encode(+{map { my $v = $bet{$_}; defined $v ? ($_ => $v) : () } @chld_col}),

        # transaction table
        @{$self->transaction_data || {}}{qw/transaction_time staff_loginid remark source app_markup/},

        # data_collection.quants_bet_variables
        defined $qv
        ? $json->encode(
            +{
                map {
                    my $v = $qv->$_;
                    $_ => eval { $v->can('db_timestamp') } ? $v->db_timestamp : defined $v ? "$v" : undef;
                } @qv_col
            })
        : undef,

        # limits
        $limits ? $json->encode($limits) : undef,
    );

    my $dbic_code = sub {
        # We want to evaluate the error message from PG.
        # So, don't allow DBD::Pg to mess it up.
        # Same as "\set VERBOSITY terse" in psql.
        local $_->{pg_errorlevel} = 0;

        # NOTE, the parens around v_fmb and v_trans in the SQL statement
        #       are necessary.
        my $stmt = $_->prepare('
SELECT (v_fmb).*, (v_trans).*
  FROM bet_v1.buy_bet(  $1::VARCHAR(12), $2::VARCHAR(3), $3::TIMESTAMP, $4::VARCHAR(50), $5::NUMERIC,
                        $6::NUMERIC, $7::TIMESTAMP, $8::TIMESTAMP, $9::TIMESTAMP, $10::BOOLEAN,
                        $11::VARCHAR(30), $12::VARCHAR(30), $13::VARCHAR(800), $14::VARCHAR(255), $15::BOOLEAN,
                        $16::INT, $17::JSON, $18::TIMESTAMP, $19::VARCHAR(24), $20::VARCHAR(800),
                        $21::BIGINT, $22::NUMERIC, $23::JSON, $24::JSONB)');

        # This can die. The caller is supposed to catch at least the following:
        # * [BIXXX => $string] - where XXX is an arbitrary combination of digits
        #                        and (uppercase?) letters
        $stmt->execute(@param);

        my $row = $stmt->fetchrow_arrayref;
        $stmt->finish;
        return $row;
    };
    my $row     = $self->db->dbic->run($dbic_code);
    my @fmb_col = BOM::Database::AutoGenerated::Rose::FinancialMarketBet->meta->columns;
    my @txn_col = BOM::Database::AutoGenerated::Rose::Transaction->meta->columns;

    my $fmb = {};
    @{$fmb}{@fmb_col} = @{$row}[0 .. $#fmb_col];

    my $txn = {};
    @{$txn}{@txn_col} = @{$row}[@fmb_col .. @fmb_col + $#txn_col];

    $self->bet_data->{id} = $fmb->{id};
    $self->bet->id($fmb->{id}) if $self->bet;

    return wantarray ? ($fmb, $txn) : $txn->{id};
}

sub batch_buy_bet {
    my $self = shift;

    # This function is able to buy the same bet on multiple accounts.
    # All accounts must have the same currency and be present in the
    # same database (brokercode). Also, loginids should be listed in
    # a certain order to prevent deadlocks.

    my @acclim;
    my $currency;
    my $accs = $self->account_data;
    my $limits = $self->limits || [];

    $currency = $accs->[0]->{currency_code};
    die "Invalid currency for loginid $accs->[0]->{client_loginid}" unless $currency;

    for (my $i = 0; $i < @$accs; $i++) {
        die "Invalid currency for loginid $accs->[$i]->{client_loginid}" unless $accs->[$i]->{currency_code} eq $currency;
        push @acclim, $accs->[$i]->{client_loginid}, $limits->[$i] ? $json->encode($limits->[$i]) : undef;
    }

    my %bet = (
        expiry_daily => 0,
        is_expired   => 0,
        is_sold      => 0,
        %{$self->bet_data},
    );

    my @chld_col = BOM::Database::AutoGenerated::Rose::FinancialMarketBet->meta->{relationships}->{$bet{bet_class}}->class->meta->columns;
    my $qv       = $self->quants_bet_variables;
    my @qv_col   = BOM::Database::AutoGenerated::Rose::QuantsBetVariable->meta->columns;

    my $transdata = $self->transaction_data || {};
    my $staff_loginid = $transdata->{staff_loginid};
    $staff_loginid = '#' . $staff_loginid if $staff_loginid;    # use #CR1234 to distinguish from non-batch buy.

    my @param = (
        # FMB stuff
        $currency,
        @bet{
            qw/purchase_time underlying_symbol
                payout_price buy_price start_time expiry_time
                settlement_time expiry_daily bet_class bet_type
                remark short_code fixed_expiry tick_count/
        },

        # FMB child table
        $json->encode(+{map { my $v = $bet{$_}; defined $v ? ($_ => $v) : () } @chld_col}),

        # transaction table
        $transdata->{transaction_time},
        $staff_loginid,
        @{$transdata}{qw/remark source app_markup/},

        # data_collection.quants_bet_variables
        $qv ? $json->encode(+{map { my $v = $qv->$_; defined $v ? ($_ => $v) : () } @qv_col}) : undef,
    );

    my $dbic_code = sub {
        # NOTE, the parens around v_fmb and v_trans in the SQL statement
        #       are necessary.
        my $stmt = $_->prepare('
WITH
acc(seq, loginid, limits) AS (VALUES
    '
                . join(",\n    ",
                map { '(' . $_ . '::INT, $' . ($_ * 2 + 23) . '::VARCHAR(12),' . ' $' . ($_ * 2 + 24) . '::JSONB)'; } 0 .. @acclim / 2 - 1)
                . ')
SELECT acc.loginid, b.r_ecode, b.r_edescription, (b.r_fmb).*, (b.r_trans).*
  FROM acc
 CROSS JOIN LATERAL
       bet_v1.buy_bet_nofail(   acc.loginid, $1::VARCHAR(3), $2::TIMESTAMP, $3::VARCHAR(50), $4::NUMERIC,
                                $5::NUMERIC, $6::TIMESTAMP, $7::TIMESTAMP, $8::TIMESTAMP, $9::BOOLEAN,
                                $10::VARCHAR(30), $11::VARCHAR(30), $12::VARCHAR(800), $13::VARCHAR(255),
                                $14::BOOLEAN, $15::INT, $16::JSON, $17::TIMESTAMP, $18::VARCHAR(24),
                                $19::VARCHAR(800), $20::BIGINT, $21::NUMERIC, $22::JSON, acc.limits) b
 ORDER BY acc.seq');

        $stmt->execute(@param, @acclim);
        return $stmt->fetchall_arrayref;
    };
    my $all_rows = $self->db->dbic->run($dbic_code);

    my @result;
    for my $row (@$all_rows) {
        my ($loginid, $ecode, $edescr) = @{$row}[0, 1, 2];

        my ($fmb, $txn);

        unless (defined $ecode) {
            my @fmb_col = BOM::Database::AutoGenerated::Rose::FinancialMarketBet->meta->columns;
            my @txn_col = BOM::Database::AutoGenerated::Rose::Transaction->meta->columns;

            $fmb = {};
            @{$fmb}{@fmb_col} = @{$row}[3 .. $#fmb_col + 3];

            $txn = {};
            @{$txn}{@txn_col} = @{$row}[@fmb_col + 3 .. @fmb_col + 3 + $#txn_col];
        }

        push @result,
            {
            fmb           => $fmb,
            txn           => $txn,
            e_code        => $ecode,
            e_description => $edescr,
            loginid       => $loginid,
            };
    }

    return \@result;
}

sub sell_bet {
    my $self = shift;

    my @param;

    my $bet    = $self->bet_data;
    my $qv     = $self->quants_bet_variables;
    my @qv_col = BOM::Database::AutoGenerated::Rose::QuantsBetVariable->meta->columns;

    if ($self->bet) {
        $bet->{$_} //= $self->bet->$_ for (qw/id sell_price sell_time/);
    }

    @param = (
        # FMB stuff
        @{$self->account_data}{qw/client_loginid currency_code/},
        @{$bet}{qw/id sell_price sell_time/},

        # FMB child table
        $bet->{absolute_barrier} ? $json->encode(+{absolute_barrier => $bet->{absolute_barrier}}) : undef,

        $bet->{is_expired} // 1,

        # transaction table
        @{$self->transaction_data || {}}{qw/transaction_time staff_loginid remark source/},

        # data_collection.quants_bet_variables
        $qv ? $json->encode(+{map { my $v = $qv->$_; defined $v ? ($_ => $v) : () } @qv_col}) : undef,
    );

    my $dbic_code = sub {
        # NOTE, the parens around v_fmb and v_trans in the SQL statement
        #       are necessary.
        my $stmt = $_->prepare('
SELECT (s.v_fmb).*, (s.v_trans).*, t.id
  FROM bet_v1.sell_bet( $1::VARCHAR(12), $2::VARCHAR(3), $3::BIGINT, $4::NUMERIC, $5::TIMESTAMP,
                        $6::JSON, $7::BOOLEAN, $8::TIMESTAMP, $9::VARCHAR(24), $10::VARCHAR(800), $11::BIGINT,
                        $12::JSON) s
  LEFT JOIN transaction.transaction t ON t.financial_market_bet_id=(s.v_fmb).id AND t.action_type=$$buy$$');
        $stmt->execute(@param);

        my $row = $stmt->fetchrow_arrayref;
        $stmt->finish;
        return $row;
    };
    my $row = $self->db->dbic->run($dbic_code);

    my @fmb_col = BOM::Database::AutoGenerated::Rose::FinancialMarketBet->meta->columns;
    my @txn_col = BOM::Database::AutoGenerated::Rose::Transaction->meta->columns;

    my $fmb = {};
    @{$fmb}{@fmb_col} = @{$row}[0 .. $#fmb_col];

    my $txn = {};
    @{$txn}{@txn_col} = @{$row}[@fmb_col .. @fmb_col + $#txn_col];

    my $buy_txn_id = $row->[-1];

    if ($self->bet) {
        $self->bet->sell_price($fmb->{sell_price});
        $self->bet->is_sold($fmb->{is_sold});
        $self->bet->is_expired($fmb->{is_expired});
    }

    return wantarray ? ($fmb, $txn, $buy_txn_id) : $txn->{id};
}

sub sell_by_shortcode {
    my $self = shift;

    my $shortcode = shift or die "No shortcode";

    my $currency = $self->account_data->[0]->{currency_code};
    die "Invalid currency for loginid " . $self->account_data->[0]->{client_loginid} unless $currency;

    my $tmp_table_values = join
        ",\n    ",
        map { '(' . $_ . '::INT, $' . ($_ + 11) . '::VARCHAR(12))'; } 1 .. scalar @{$self->account_data};

    my @qv_col    = BOM::Database::AutoGenerated::Rose::QuantsBetVariable->meta->columns;
    my $qv        = $self->quants_bet_variables;
    my $transdata = $self->transaction_data || {};
    my $dbic_code = sub {
        my $stmt = $_->prepare('
WITH
acc( seq, loginid) AS (VALUES ' . $tmp_table_values . ')
SELECT acc.loginid, b.r_ecode, b.r_edescription, t.id, (b.v_fmb).*, (b.v_trans).*
  FROM acc
 CROSS JOIN LATERAL
       bet_v1.sell_by_shortcode(

 acc.loginid,
 $1::VARCHAR(3),
 $2::VARCHAR(255),
 $3::NUMERIC,
 $4::TIMESTAMP,
 $5::JSON,
 $6::BOOLEAN,
 $7::TIMESTAMP,
 $8::VARCHAR(24),
 $9::VARCHAR(800),
 $10::BIGINT,
 $11::JSON

) b
LEFT JOIN transaction.transaction t ON t.financial_market_bet_id=(b.v_fmb).id AND t.action_type=$$buy$$
 ORDER BY acc.seq');
        $stmt->execute(
            $currency,                        # -- 2
            $shortcode,                       # -- 3
            $self->bet_data->{sell_price},    # -- 4
            $self->bet_data->{sell_time},     # -- 5
            $self->bet_data->{absolute_barrier}
            ? $json->encode(+{absolute_barrier => $self->bet_data->{absolute_barrier}})
            : undef,                          # -- 6
            $self->bet_data->{is_expired} // 1,    # -- 7

            $transdata->{transaction_time},        # -- 8
            $transdata->{staff_loginid} ? ('#' . $transdata->{staff_loginid}) : undef,    # -- 9
            $transdata->{remark} // '',                                                   # -- 10
            $transdata->{source},                                                         # -- 11
            $qv ? $json->encode(+{map { my $v = $qv->$_; defined $v ? ($_ => $v) : () } @qv_col}) : undef,    # -- 12
            map { $_->{client_loginid} } @{$self->account_data}                                                       # -- 13...
        );
        my $all_rows = $stmt->fetchall_arrayref;
        $stmt->finish;
        return $all_rows;
    };
    my $all_rows = $self->db->dbic->run($dbic_code);
    my $result;
    for my $r (@$all_rows) {
        my @row = @$r;

        my $loginid   = shift @row;
        my $ecode     = shift @row;
        my $edescr    = shift @row;
        my $buy_tr_id = shift @row;
        if ($ecode) {
            push @$result,
                {
                fmb           => {},
                txn           => {},
                loginid       => $loginid,
                e_code        => $ecode,
                e_description => $edescr,
                };
        } else {

            my @fmb_col = BOM::Database::AutoGenerated::Rose::FinancialMarketBet->meta->columns;
            my @txn_col = BOM::Database::AutoGenerated::Rose::Transaction->meta->columns;

            my $fmb = {};
            @{$fmb}{@fmb_col} = @row[0 .. $#fmb_col];

            my $txn = {};
            @{$txn}{@txn_col} = @row[@fmb_col .. @fmb_col + $#txn_col];

            push @$result, {
                fmb       => $fmb,
                txn       => $txn,
                buy_tr_id => $buy_tr_id,
                loginid   => $loginid,     ### Not sure, maybe need to remove
            };
        }
    }

    return $result;
}

sub batch_sell_bet {
    my $self = shift;

    my $bets = $self->bet_data;
    my $qvs  = $self->quants_bet_variables || [];
    my $txns = $self->transaction_data || [];

    my @qv_col = BOM::Database::AutoGenerated::Rose::QuantsBetVariable->meta->columns;

    # NOTE, this function can only be used to sell multiple contracts for the same account.
    #       If you need to sell contracts for multiple accounts, you can use
    #
    #           bet_v1.sell_bet(loginid, currency, ...)
    #
    #       in a similar way. However, be aware that this can lead to deadlocks because
    #       the order in which the accounts are updated is not determined. If you still
    #       want to go this way, please order the bets by client_loginid and currency_code
    #       before the query. If in doubt, ask your friendly DBA team.

    # NOTE, the parens around s.v_fmb and s.v_trans in the SQL statement
    #       are necessary.
    my $sql = '
WITH
acc(account_id,currency_code)  AS (SELECT id, currency_code
                       FROM transaction.account
                      WHERE client_loginid=$1
                        AND currency_code=$2
                        FOR UPDATE),
bets(id, sell_price, sell_time, chld, is_expired, transaction_time, staff_loginid, remark, source, qv) AS (VALUES
    ' . join(
        ",\n    ",
        map {
                  '($'
                . ($_ * 10 + 3)
                . '::BIGINT,' . ' $'
                . ($_ * 10 + 4)
                . '::NUMERIC,' . ' $'
                . ($_ * 10 + 5)
                . '::TIMESTAMP,' . ' $'
                . ($_ * 10 + 6)
                . '::JSON,' . ' $'
                . ($_ * 10 + 7)
                . '::BOOLEAN,' . ' $'
                . ($_ * 10 + 8)
                . '::TIMESTAMP,' . ' $'
                . ($_ * 10 + 9)
                . '::VARCHAR(24),' . ' $'
                . ($_ * 10 + 10)
                . '::VARCHAR(800),' . ' $'
                . ($_ * 10 + 11)
                . '::BIGINT,' . ' $'
                . ($_ * 10 + 12)
                . '::JSON)';
        } 0 .. $#$bets
        )
        . ')
SELECT (s.v_fmb).*, (s.v_trans).*, t.id
  FROM bets b
 CROSS JOIN acc a
 CROSS JOIN LATERAL bet_v1.sell_bet(a.account_id,
                                    a.currency_code,
                                    b.id,
                                    b.sell_price,
                                    b.sell_time,
                                    b.chld,
                                    b.is_expired,
                                    b.transaction_time,
                                    b.staff_loginid,
                                    b.remark,
                                    b.source,
                                    b.qv) s
 LEFT JOIN transaction.transaction t ON t.financial_market_bet_id=(s.v_fmb).id AND t.action_type=$$buy$$
 ORDER BY (s.v_trans).id DESC';

    my @param = @{$self->account_data}{qw/client_loginid currency_code/};

    for (my $i = 0; $i < @$bets; $i++) {
        my $bet       = $bets->[$i];
        my $qv        = $qvs->[$i];
        my $transdata = $txns->[$i];
        push @param, (
            # FMB stuff
            @{$bet}{qw/id sell_price sell_time/},

            # FMB child table
            $bet->{absolute_barrier} ? $json->encode(+{absolute_barrier => $bet->{absolute_barrier}}) : undef,

            $bet->{is_expired} // 1,

            # transaction table
            @{$transdata || {}}{qw/transaction_time staff_loginid remark source/},

            # data_collection.quants_bet_variables
            $qv ? $json->encode(+{map { my $v = $qv->$_; defined $v ? ($_ => $v) : () } @qv_col}) : undef,
        );
    }

    my $dbic_code = sub {
        my $stmt = $_->prepare($sql);
        $stmt->execute(@param);
        return $stmt->fetchall_arrayref;
    };

    my $all_rows = $self->db->dbic->run($dbic_code);
    my @fmb_col  = BOM::Database::AutoGenerated::Rose::FinancialMarketBet->meta->columns;
    my @txn_col  = BOM::Database::AutoGenerated::Rose::Transaction->meta->columns;

    my @res;
    for my $row (@$all_rows) {
        my $fmb = {};
        @{$fmb}{@fmb_col} = @{$row}[0 .. $#fmb_col];
        my $txn = {};
        @{$txn}{@txn_col} = @{$row}[@fmb_col .. @fmb_col + $#txn_col];
        push @res,
            {
            fmb        => $fmb,
            txn        => $txn,
            buy_txn_id => $row->[-1],
            };
    }

    return \@res;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
