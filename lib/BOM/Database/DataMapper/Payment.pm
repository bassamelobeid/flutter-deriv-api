package BOM::Database::DataMapper::Payment;

=head1 NAME

BOM::Database::DataMapper::Payment

=head1 DESCRIPTION

This is a class that will collect general payment queries and is parent to other payment data mapper classes. Queries like last payment transaction time can be queried in here.

=head1 VERSION

0.1

=cut

use Moose;
use BOM::Database::Model::Constants;
use BOM::Database::AutoGenerated::Rose::Transaction::Manager;
use BOM::Database::AutoGenerated::Rose::Payment::Manager;
use BOM::Database::Model::Constants;
use Syntax::Keyword::Try;
use Date::Utility;
extends 'BOM::Database::DataMapper::AccountBase';

=head1 METHODS

=over

=item get_summary

get summary of deposits and withdrawals

=cut

sub get_summary {
    my ($self, $args) = @_;
    my $from_date = $args->{from_date} // '1970-01-01';
    my $to_date   = $args->{to_date}   // Date::Utility->new()->datetime;

    my $dbic = $self->db->dbic;

    return $dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                'SELECT * FROM payment.get_account_payments_summary(?,?,?)',
                {Slice => {}},
                $self->account->id, $from_date, $to_date
            );
        },
    );
}

=item get_total_deposit

get the total deposit made by an account

=cut

sub get_total_deposit {
    my $self = shift;
    my $dbic = $self->db->dbic;

    # exclude compacted statement payment record
    my $sql = q{
        SELECT payment.get_total_deposit(?);
    };

    my $total_deposit = 0;
    try {
        my $payment_arrayref = $dbic->run(
            fixup => sub {
                local $_->{'RaiseError'} = 1;

                my $sth = $_->prepare($sql);
                $sth->execute($self->client_loginid);

                return $sth->fetchrow_arrayref;
            });

        if ($payment_arrayref && $payment_arrayref->[0]) {
            $total_deposit = $payment_arrayref->[0];
        }
    } catch {
        Carp::croak("BOM::Database::AutoGenerated::Rose::Payment - get_total_deposit [$@]");
    }

    return $total_deposit;
}

=item get_total_withdrawal

get the total withdrawal of client's default currency

usage :
             my $payment_data_mapper = BOM::Database::DataMapper::Payment->new({
                                             'client_loginid' => 'CR0031',
                                      });
            $payment_data_mapper->get_total_withdrawal
            $payment_data_mapper->get_total_withdrawal({ start_time => Date::Utility->new(Date::Utility->new->epoch - 2 * 86400) })

get_total_withdrawal

=cut

sub get_total_withdrawal {
    my $self     = shift;
    my $args_ref = shift;
    my ($start_time, $excludes) = @{$args_ref}{'start_time', 'exclude'};
    my $dbic = $self->db->dbic;
    my @bind_values;

    my $sql = q{
        SELECT payment.get_total_withdrawal(?::VARCHAR, ?::TIMESTAMP, ?::VARCHAR[]);
    };

    # Push arguments for get_total_withdrawal SQL function. Push undef to maintain method signature
    push @bind_values, $self->client_loginid;
    push @bind_values, $start_time ? $start_time->datetime_yyyymmdd_hhmmss : undef;
    push @bind_values, $excludes;

    my $total_withdrawal = 0;
    try {
        my $payment_arrayref = $dbic->run(
            fixup => sub {
                local $_->{'RaiseError'} = 1;

                my $sth = $_->prepare($sql);
                $sth->execute(@bind_values);
                return $sth->fetchrow_arrayref();
            });

        if ($payment_arrayref && $payment_arrayref->[0]) {
            $total_withdrawal = $payment_arrayref->[0];
        }
    } catch {
        Carp::croak("BOM::Database::AutoGenerated::Rose::Payment - get_total_withdrawal [$@]");
    }

    return $total_withdrawal;
}

=item get_total_free_gift_deposit

Get total free gift amount for account.

=cut

sub get_total_free_gift_deposit {
    my $self = shift;

    my $payment_record = BOM::Database::AutoGenerated::Rose::Payment::Manager->get_payment(
        require_objects => [@{$self->_mapper_required_objects}, 'account'],
        select          => ['SUM(t1.amount) as amount'],
        query           => [
            't2.client_loginid'    => [$self->client_loginid],
            't2.currency_code'     => [$self->currency_code],
            't1.payment_type_code' => {eq => $BOM::Database::Model::Constants::PAYMENT_TYPE_FREE_GIFT},
            't1.amount'            => {gt => 0},
        ],
        db => $self->db,
    );

    if (scalar @{$payment_record} == 1 and $payment_record->[0]->amount) {
        return $payment_record->[0]->amount;
    }

    return 0;
}

=item get_total_free_gift_rescind_withdrawal

=cut

sub get_total_free_gift_rescind_withdrawal {
    my $self = shift;

    my $payment_record = BOM::Database::AutoGenerated::Rose::Payment::Manager->get_payment(
        require_objects => [@{$self->_mapper_required_objects}, 'account'],
        select          => ['SUM(-1*t1.amount) as amount'],
        query           => [
            't2.client_loginid'    => [$self->client_loginid],
            't2.currency_code'     => [$self->currency_code],
            't1.payment_type_code' => 'free_gift',
            't1.amount'            => {lt => 0},
        ],
        db => $self->db,
    );

    if (scalar @{$payment_record} == 1 and $payment_record->[0]->amount) {
        return $payment_record->[0]->amount;
    }

    return 0;
}

has first_funding => (
    is         => 'rw',
    lazy_build => 1,
);

sub _build_first_funding {
    my $self = shift;

    return BOM::Database::AutoGenerated::Rose::Payment::Manager->get_payment(
        require_objects => [@{$self->_mapper_required_objects}, 'account'],
        query           => [
            client_loginid       => $self->client_loginid,
            is_default           => 1,
            payment_gateway_code => {ne => 'free_gift'},
            payment_gateway_code => {ne => 'compacted_statement'},
            payment_gateway_code => {ne => 'cancellation'},
            payment_gateway_code => {ne => 'closed_account'},
            payment_gateway_code => {ne => 'miscellaneous'},
            payment_gateway_code => {ne => 'adjustment'},
            payment_gateway_code => {ne => 'affiliate_reward'},
            payment_gateway_code => {ne => 'payment_fee'},
            payment_gateway_code => {ne => 'virtual_credit'},
            payment_gateway_code => {ne => 'account_transfer'},
            payment_gateway_code => {ne => 'currency_conversion_transfer'},
            amount               => {gt => 0},

        ],
        sort_by => 'payment_time ASC',
        limit   => 1,
        db      => $self->db,
    )->[0];

}

=item get_client_payment_count_by

Get the number of payments of client has been done by

    my $payment_data_mapper = BOM::Database::DataMapper::Payment->new(
        {
            'client_loginid' => $client->loginid,
        });

    $payment_data_mapper->get_client_payment_count_by(
        {
            payment_gateway_code  => [$BOM::Database::Model::Constants::PAYMENT_GATEWAY_DATACASH, $BOM::Database::Model::Constants::PAYMENT_GATEWAY_BANK_WIRE], # Optional
            action_type => $BOM::Database::Model::Constants::DEPOSIT, # Optional
            payment_type_code => $BOM::Database::Model::Constants::PAYMENT_TYPE_CREDIT_DEBIT_CARD, # Optional
        });

=cut

sub get_client_payment_count_by {
    my $self    = shift;
    my $arg_ref = shift;

    Carp::croak('ERROR: There is no valid client_loginid') if not $self->client_loginid;

    my @valid_keys = qw/
        action_type
        since
        payment_gateway_code
        /;

    my @query;
    push @query, (client_loginid => $self->client_loginid);
    push @query, (is_default     => 1);

    foreach my $key (sort keys %$arg_ref) {
        if (not grep { /^$key$/ } @valid_keys) {
            Carp::croak("Invalid parameter [$key] in " . __PACKAGE__);
        }

        if ($key eq 'since') {
            push @query, (payment_time => {ge => $arg_ref->{$key}});
            next;
        }
        push @query, ($key => $arg_ref->{$key});
    }

    my $payment_count = BOM::Database::AutoGenerated::Rose::Payment::Manager->get_payment_count(
        require_objects => [@{$self->_mapper_required_objects}, 'account', 'transaction'],
        query           => \@query,
        db              => $self->db,
        debug           => $self->debug,
    );

    return $payment_count;
}

=item get_payment_count_exclude_gateway

Get the number of payments exclude payment gateway codes.

    my $payment_data_mapper = BOM::Database::DataMapper::Payment->new(
        {
            'client_loginid' => $client->loginid,
        });

    $payment_data_mapper->get_payment_count_exclude_gateway(
        {
            exclude => [$BOM::Database::Model::Constants::PAYMENT_GATEWAY_DATACASH, $BOM::Database::Model::Constants::PAYMENT_GATEWAY_BANK_WIRE],
        });

=cut

sub get_payment_count_exclude_gateway {
    my $self    = shift;
    my $arg_ref = shift;

    my $exclude = $arg_ref->{'exclude'};

    my $payment_count = BOM::Database::AutoGenerated::Rose::Payment::Manager->get_payment_count(
        require_objects => [@{$self->_mapper_required_objects}, 'account'],
        query           => [
            'client_loginid'        => $self->client_loginid,
            '!payment_gateway_code' => $exclude,
            'is_default'            => 1,
        ],
        db    => $self->db,
        debug => $self->debug,
    );

    return $payment_count;
}

=item get_transaction_id_of_account_by_comment

Get transaction_id of account by comment

=cut

sub get_transaction_id_of_account_by_comment {
    my $self    = shift;
    my $arg_ref = shift;

    ## This can be an expensive query, so we want it to run on the replica
    my $replica = BOM::Database::ClientDB->new({
        broker_code => $self->broker_code,
        operation   => 'replica',
    });

    my $sql = <<'SQL';
SELECT * FROM transaction.get_txnid_by_amount_and_payment_remark (
    p_amount        => $1,
    p_remark        => $2,
    p_loginid       => $3,
    p_currency_code => $4
)
SQL

    my $payment = $replica->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref($sql, undef, $arg_ref->{'amount'}, $arg_ref->{'comment'}, $self->client_loginid, $self->currency_code);
        });

    if (@$payment) {
        return $payment->[0][0];
    }

    return;
}

=item is_duplicate_manual_payment

Check the remark, date and amount of payment to find duplicate, used for manual deposit by payments team

=cut

sub is_duplicate_manual_payment {
    my $self = shift;
    my $args = shift;

    my $date         = $args->{'date'};
    my $epoch_before = $date->epoch - $date->seconds_after_midnight;
    my $epoch_after  = $epoch_before + 24 * 60 * 60;

    my $payment = BOM::Database::AutoGenerated::Rose::Payment::Manager->get_payment(
        require_objects => ['account'],
        query           => [
            client_loginid => $self->client_loginid,
            currency_code  => $self->currency_code,
            remark         => {ilike => '%' . $args->{remark} . '%'},
            payment_time   => {ge    => Date::Utility->new($epoch_before)->datetime_yyyymmdd_hhmmss},
            payment_time   => {lt    => Date::Utility->new($epoch_after)->datetime_yyyymmdd_hhmmss},
            amount         => $args->{amount}
        ],
        db => $self->db,
    );

    if (scalar @{$payment} > 0) {
        return 1;
    }
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

=back

=head1 AUTHOR

RMG Company

=head1 COPYRIGHT

(c) 2010 RMG Technology (Malaysia) Sdn Bhd

=cut

1;
