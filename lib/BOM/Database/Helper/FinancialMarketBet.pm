package BOM::Database::Helper::FinancialMarketBet;

use Moose;
use BOM::Database::AutoGenerated::Rose::FinancialMarketBet;
use BOM::Database::AutoGenerated::Rose::QuantsBetVariable;
use BOM::Database::Model::DataCollection::QuantsBetVariables;
use BOM::Config::Runtime;
use Rose::DB;
use Scalar::Util qw(looks_like_number);
use JSON::MaybeXS ();
use Encode;
use Carp;

has 'account_data' => (
    is  => 'rw',
    isa => 'HashRef|ArrayRef',
);

has fmb_ids => (
    is      => 'ro',
    isa     => 'ArrayRef',
    default => sub { [] },
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

has 'app_config' => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 _build_app_config

    lazy build function of the attribute app_config
    return: L<App::Config::Chronicle> object

=cut

sub _build_app_config {
    return BOM::Config::Runtime->instance->app_config;
}

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
    my $trans    = $self->transaction_data || {};

    my @param = (
        # FMB stuff
        @{$self->account_data}{qw/client_loginid currency_code/},
        @bet{
            qw/ fmb_id purchase_time underlying_symbol
                payout_price buy_price start_time expiry_time
                settlement_time expiry_daily bet_class bet_type
                remark short_code fixed_expiry tick_count/
        },

        # FMB child table
        Encode::encode_utf8($json->encode(+{map { my $v = $bet{$_}; defined $v ? ($_ => $v) : () } @chld_col})),

        # transaction table
        @{$trans}{qw/transaction_time staff_loginid remark source app_markup/},
        $bet{quantity} // 1,
        $trans->{session_token},

        # data_collection.quants_bet_variables
        defined $qv
        ? Encode::encode_utf8(
            $json->encode(
                +{
                    map {
                        my $v = $qv->$_;
                        $_ => eval { $v->can('db_timestamp') } ? $v->db_timestamp : defined $v ? "$v" : undef;
                    } @qv_col
                }))
        : undef,

        # limits
        $limits ? Encode::encode_utf8($json->encode($limits)) : undef,
        $self->app_config->quants->ultra_short_duration + 0 || 300,
    );
    my $dbic_code = sub {

        # NOTE, the parens around v_fmb and v_trans in the SQL statement
        #       are necessary.
        my $stmt = $_->prepare('
SELECT (v_fmb).*, (v_trans).*
  FROM bet_v1.buy_bet(  $1::VARCHAR(12), $2::TEXT, $3::BIGINT, $4::TIMESTAMP, $5::VARCHAR(50), $6::NUMERIC,
                        $7::NUMERIC, $8::TIMESTAMP, $9::TIMESTAMP, $10::TIMESTAMP, $11::BOOLEAN,
                        $12::VARCHAR(30), $13::VARCHAR(30), $14::VARCHAR(800), $15::VARCHAR(255), $16::BOOLEAN,
                        $17::INT, $18::JSON, $19::TIMESTAMP, $20::VARCHAR(24), $21::VARCHAR(800),
                        $22::BIGINT, $23::NUMERIC, $24::INT, $25::TEXT, $26::JSON, $27::JSONB, $28::INT)');

        # This can die. The caller is supposed to catch at least the following:
        # * [BIXXX => $string] - where XXX is an arbitrary combination of digits
        #                        and (uppercase?) letters
        $stmt->execute(@param);

        my $row = $stmt->fetchrow_arrayref;
        $stmt->finish;
        return $row;
    };
    my $row     = $self->db->dbic->run(ping => $dbic_code);
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
    my $accs    = $self->account_data;
    my $limits  = $self->limits || [];
    my $fmb_ids = $self->fmb_ids;

    $currency = $accs->[0]->{currency_code};
    die "Invalid currency for loginid $accs->[0]->{client_loginid}" unless $currency;

    for (my $i = 0; $i < @$accs; $i++) {
        die "Invalid currency for loginid $accs->[$i]->{client_loginid}" unless $accs->[$i]->{currency_code} eq $currency;
        my $fmbid = $fmb_ids->[$i] // undef;
        push @acclim, $fmbid, $accs->[$i]->{client_loginid}, $limits->[$i] ? Encode::encode_utf8($json->encode($limits->[$i])) : undef;
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

    my $transdata     = $self->transaction_data || {};
    my $staff_loginid = $transdata->{staff_loginid};
    $staff_loginid = '#' . $staff_loginid if $staff_loginid;    # use #CR1234 to distinguish from non-batch buy.

    my @param = (
        # FMB stuff
        $currency,
        @bet{
            qw/ purchase_time underlying_symbol
                payout_price buy_price start_time expiry_time
                settlement_time expiry_daily bet_class bet_type
                remark short_code fixed_expiry tick_count/
        },

        # FMB child table
        Encode::encode_utf8($json->encode(+{map { my $v = $bet{$_}; defined $v ? ($_ => $v) : () } @chld_col})),

        # transaction table
        $transdata->{transaction_time},
        $staff_loginid,
        @{$transdata}{qw/remark source app_markup/},
        $bet{quantity} // 1,
        $transdata->{session_token},

        # data_collection.quants_bet_variables
        $qv ? Encode::encode_utf8($json->encode(+{map { my $v = $qv->$_; defined $v ? ($_ => "$v") : () } @qv_col})) : undef,
    );

    my $dbic_code = sub {
        # NOTE, the parens around v_fmb and v_trans in the SQL statement
        #       are necessary.
        my $stmt = $_->prepare('
WITH
acc(fmbid, loginid, limits) AS (VALUES
    '
                . join(",\n    ",
                map { '($' . ($_ * 3 + 25) . '::BIGINT, $' . ($_ * 3 + 26) . '::VARCHAR(12),' . ' $' . ($_ * 3 + 27) . '::JSONB)'; }
                    0 .. @acclim / 3 - 1)
                . ')
SELECT acc.loginid, b.r_ecode, b.r_edescription, (b.r_fmb).*, (b.r_trans).*
  FROM acc
 CROSS JOIN LATERAL
       bet_v1.buy_bet_nofail(   acc.loginid, $1::TEXT, acc.fmbid, $2::TIMESTAMP, $3::VARCHAR(50), $4::NUMERIC,
                                $5::NUMERIC, $6::TIMESTAMP, $7::TIMESTAMP, $8::TIMESTAMP, $9::BOOLEAN,
                                $10::VARCHAR(30), $11::VARCHAR(30), $12::VARCHAR(800), $13::VARCHAR(255),
                                $14::BOOLEAN, $15::INT, $16::JSON, $17::TIMESTAMP, $18::VARCHAR(24),
                                $19::VARCHAR(800), $20::BIGINT, $21::NUMERIC, $22::INT, $23::TEXT, $24::JSON, acc.limits, $'
                . ((@acclim / 3 - 1) * 3 + 28) . '::INT) b
 ORDER BY acc.fmbid');

        $stmt->execute(@param, @acclim, ($self->app_config->quants->ultra_short_duration + 0) || 300);
        return $stmt->fetchall_arrayref;
    };
    my $all_rows = $self->db->dbic->run(ping => $dbic_code);

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
        $bet->{absolute_barrier}       ? Encode::encode_utf8($json->encode(+{absolute_barrier => $bet->{absolute_barrier}}))
        : defined $bet->{is_cancelled} ? Encode::encode_utf8($json->encode(+{is_cancelled     => $bet->{is_cancelled}}))
        : undef,

        $bet->{is_expired} // 1,

        # transaction table
        @{$self->transaction_data || {}}{qw/transaction_time staff_loginid remark source/},
        $bet->{quantity} // 1,

        # data_collection.quants_bet_variables
        $qv ? Encode::encode_utf8($json->encode(+{map { my $v = $qv->$_; defined $v ? ($_ => "$v") : () } @qv_col})) : undef,
        ($self->app_config->quants->ultra_short_duration + 0) || 300,

        # for contracts where we need to verify if child table is updated. Currently, we have multiplier contract that
        # requires this functionality
        ($bet->{verify_child} ? Encode::encode_utf8($json->encode($bet->{verify_child})) : undef),
    );

    my $dbic_code = sub {
        # NOTE, the parens around v_fmb and v_trans in the SQL statement
        #       are necessary.
        my $stmt = $_->prepare('
SELECT (s.v_fmb).*, (s.v_trans).*, t.id
  FROM bet_v1.sell_bet( $1::VARCHAR(12), $2::TEXT, $3::BIGINT, $4::NUMERIC, $5::TIMESTAMP,
                        $6::JSON, $7::BOOLEAN, $8::TIMESTAMP, $9::VARCHAR(24), $10::VARCHAR(800), $11::BIGINT,
                        $12::INT, $13::JSON, $14::INT, $15::JSONB) s
  LEFT JOIN transaction.transaction t ON t.financial_market_bet_id=(s.v_fmb).id AND t.action_type=$$buy$$');
        $stmt->execute(@param);

        my $row = $stmt->fetchrow_arrayref;
        $stmt->finish;
        return $row;
    };
    my $row = $self->db->dbic->run(ping => $dbic_code);

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
        map { '(' . $_ . '::INT, $' . ($_ + 13) . '::VARCHAR(12))'; } 1 .. scalar @{$self->account_data};

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
 $1::TEXT,
 $2::VARCHAR(255),
 $3::NUMERIC,
 $4::TIMESTAMP,
 $5::JSON,
 $6::BOOLEAN,
 $7::TIMESTAMP,
 $8::VARCHAR(24),
 $9::VARCHAR(800),
 $10::BIGINT,
 $11::INT,
 $12::JSON,
 $13::INT
) b
LEFT JOIN transaction.transaction t ON t.financial_market_bet_id=(b.v_fmb).id AND t.action_type=$$buy$$
 ORDER BY acc.seq');
        $stmt->execute(
            $currency,                             # -- 2
            $shortcode,                            # -- 3
            $self->bet_data->{sell_price},         # -- 4
            $self->bet_data->{sell_time},          # -- 5
            $self->bet_data->{absolute_barrier} ? Encode::encode_utf8($json->encode(+{absolute_barrier => $self->bet_data->{absolute_barrier}}))
            : $self->bet_data->{is_cancelled}   ? Encode::encode_utf8($json->encode(+{is_cancelled     => $self->bet_data->{is_cancelled}}))
            : undef,                               # -- 6
            $self->bet_data->{is_expired} // 1,    # -- 7

            $transdata->{transaction_time},                                                                                          # -- 8
            $transdata->{staff_loginid} ? ('#' . $transdata->{staff_loginid}) : undef,                                               # -- 9
            $transdata->{remark} // '',                                                                                              # -- 10
            $transdata->{source},                                                                                                    # -- 11
            $self->bet_data->{quantity} // 1,
            $qv ? Encode::encode_utf8($json->encode(+{map { my $v = $qv->$_; defined $v ? ($_ => "$v") : () } @qv_col})) : undef,    # -- 12
            ($self->app_config->quants->ultra_short_duration + 0) || 300,                                                            # --13
            (map { $_->{client_loginid} } @{$self->account_data}),                                                                   # --14
        );
        my $all_rows = $stmt->fetchall_arrayref;
        $stmt->finish;
        return $all_rows;
    };
    my $all_rows = $self->db->dbic->run(ping => $dbic_code);
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
    my $txns = $self->transaction_data     || [];

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
bets(id, sell_price, sell_time, chld, is_expired, transaction_time, staff_loginid, remark, source, quantity, qv, verify_child) AS (VALUES
    ' . join(
        ",\n    ",
        map {
                  '($'
                . ($_ * 12 + 4)
                . '::BIGINT,' . ' $'
                . ($_ * 12 + 5)
                . '::NUMERIC,' . ' $'
                . ($_ * 12 + 6)
                . '::TIMESTAMP,' . ' $'
                . ($_ * 12 + 7)
                . '::JSON,' . ' $'
                . ($_ * 12 + 8)
                . '::BOOLEAN,' . ' $'
                . ($_ * 12 + 9)
                . '::TIMESTAMP,' . ' $'
                . ($_ * 12 + 10)
                . '::VARCHAR(24),' . ' $'
                . ($_ * 12 + 11)
                . '::VARCHAR(800),' . ' $'
                . ($_ * 12 + 12)
                . '::BIGINT,' . ' $'
                . ($_ * 12 + 13)
                . '::INT,' . ' $'
                . ($_ * 12 + 14)
                . '::JSON,' . ' $'
                . ($_ * 12 + 15)
                . '::JSONB)'
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
                                    b.quantity,
                                    b.qv,
                                    $3::INT,
                                    b.verify_child) s
 LEFT JOIN transaction.transaction t ON t.financial_market_bet_id=(s.v_fmb).id AND t.action_type=$$buy$$
 ORDER BY (s.v_trans).id DESC';

    my @param = @{$self->account_data}{qw/client_loginid currency_code/};
    push @param, ($self->app_config->quants->ultra_short_duration + 0) || 300;

    for (my $i = 0; $i < @$bets; $i++) {
        my $bet       = $bets->[$i];
        my $qv        = $qvs->[$i];
        my $transdata = $txns->[$i];
        push @param, (
            # FMB stuff
            @{$bet}{qw/id sell_price sell_time/},

            # FMB child table
            $bet->{absolute_barrier} ? Encode::encode_utf8($json->encode(+{absolute_barrier => $bet->{absolute_barrier}})) : undef,

            $bet->{is_expired} // 1,

            # transaction table
            @{$transdata || {}}{qw/transaction_time staff_loginid remark source/},
            $bet->{quantity} // 1,

            # data_collection.quants_bet_variables
            # TODO NOTICE the `$v` should be changed from string to number. Otherwise Cpanel::JSON::XS will change integer string '123' to float '123.0'
            # please refer to https://trello.com/c/4sjibBuP/6197-json-handling-1#comment-5a1b88650c5575743c027ef7
            # we should change that value directly in module BOM::Database::Model::DataCollection::QuantsBetVariables
            $qv ? Encode::encode_utf8($json->encode(+{map { my $v = $qv->$_; defined $v ? ($_ => "$v") : () } @qv_col})) : undef,

            # for contracts where we need to verify if child table is updated. Currently, we have multiplier contract that
            # requires this functionality
            ($bet->{verify_child} ? Encode::encode_utf8($json->encode($bet->{verify_child})) : undef),
        );
    }

    my $dbic_code = sub {
        my $stmt = $_->prepare($sql);
        $stmt->execute(@param);
        return $stmt->fetchall_arrayref;
    };

    my $all_rows = $self->db->dbic->run(ping => $dbic_code);
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

=head2 update_multiplier_contract

A specific function update limit orders of Multiplier contract.

=cut

sub update_multiplier_contract {
    my ($self, $args) = @_;

    my ($contract_id, $take_profit, $stop_loss) = @{$args}{qw(contract_id take_profit stop_loss)};

    my @args = ($contract_id, $take_profit, $stop_loss, Date::Utility->new->db_timestamp);

    my $sql = q{SELECT (updated).* , msg from bet.update_multiplier_v2(?,?,?,?)};

    my $res = $self->db->dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute(@args);
            $sth->fetchall_hashref('financial_market_bet_id');
        });

    unless ($res->{$contract_id}) {
        $res->{error} = $res->{''}->{msg};
    }

    return $res;
}
no Moose;
__PACKAGE__->meta->make_immutable;

1;
