package BOM::Database::DataMapper::Payment::PaymentAgentTransfer;

use Moose;
use BOM::Database::AutoGenerated::Rose::PaymentAgentTransfer::Manager;
use BOM::Database::AutoGenerated::Rose::Transaction::Manager;
extends 'BOM::Database::DataMapper::Payment';

has '_mapper_required_objects' => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    init_arg => undef,
    default  => sub { return ['payment_agent_transfer'] },
);

=head1 METHODS

=over

=item get_today_client_payment_agent_transfer_total_amount

=cut

sub get_today_client_payment_agent_transfer_total_amount {
    my $self = shift;

    my $today = Date::Utility::today->date;
    my $sql   = qq{
        SELECT
            ROUND(SUM(ABS(p.amount)), 2) AS amount
        FROM
            payment.payment p,
            transaction.account a
        WHERE
            p.account_id = a.id
            AND a.client_loginid = ?
            AND a.is_default = 'TRUE'
            AND p.payment_gateway_code = 'payment_agent_transfer'
            AND p.payment_time::DATE >= '$today';
    };

    my $dbh = $self->db->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->execute($self->client_loginid);
    my $amount = 0;
    if (my $result = $sth->fetchrow_hashref()) {
        $amount = $result->{amount} || 0;
    }

    return $amount;
}

=item get_today_payment_agent_withdrawal_sum_count

=cut

sub get_today_payment_agent_withdrawal_sum_count {
    my $self = shift;

    my $sql = q{
        SELECT
            coalesce( round(sum(-1 * p.amount), 2), 0 ) as amount,
            count(*) as count
        FROM
            payment.payment p,
            transaction.account a
        WHERE
            p.account_id = a.id
            AND a.client_loginid = ?
            AND a.is_default = 'TRUE'
            AND p.payment_gateway_code = 'payment_agent_transfer'
            AND p.amount < 0
            AND p.payment_time::DATE >= 'today'
    };

    my $dbh = $self->db->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->execute($self->client_loginid);

    my ($amount, $count) = (0, 0);
    if (my $result = $sth->fetchrow_hashref()) {
        $amount = $result->{amount};
        $count  = $result->{count};
    }

    return ($amount, $count);
}

=item get_today_client_payment_agent_transfer_deposit_count
    it count number of deposit for the day via payment agent.
    return deposit count
=back
=cut

sub get_today_client_payment_agent_transfer_deposit_count {
    my $self = shift;

    my $sql = q{
        SELECT count(*)
        FROM
            payment.payment p,
            transaction.account a
        WHERE
            p.account_id = a.id
            AND a.client_loginid = ?
            AND a.is_default = 'TRUE'
            AND p.payment_gateway_code = 'payment_agent_transfer'
            AND p.amount > 0
            AND p.payment_time::DATE >= 'today'
    };

    my $dbh = $self->db->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->execute($self->client_loginid);

    my $result = $sth->fetchrow_hashref();
    return $result->{count};
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

=head1 NAME
BOM::Database::DataMapper::Payment::PaymentAgentTransfer - This is a class that collects payment agent transfer queries.
=head1 VERSION
 0.1
=head1 AUTHOR
 RMG Company
=cut
