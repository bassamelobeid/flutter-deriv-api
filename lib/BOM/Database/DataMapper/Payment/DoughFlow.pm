package BOM::Database::DataMapper::Payment::DoughFlow;

use Moose;
use BOM::Database::AutoGenerated::Rose::Doughflow::Manager;
extends 'BOM::Database::DataMapper::Payment';

has '_mapper_required_objects' => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    init_arg => undef,
    default  => sub { return ['doughflow'] },
);

=head2 get_doughflow_withdrawal_count_by_trace_id

Get the number of withdrawals by trace_id

=cut

sub get_doughflow_withdrawal_count_by_trace_id {
    my $self     = shift;
    my $trace_id = shift;

    my $payment = BOM::Database::AutoGenerated::Rose::Doughflow::Manager->get_doughflow(
        require_objects => ['payment'],
        query           => [
            account_id => $self->account->id,
            remark     => {like => '%trace_id=' . $trace_id . '%'},
        ],
        db => $self->db,
    );

    return scalar @{$payment};
}

=head2 get_doughflow_withdrawal_amount_by_trace_id

Get the amount of withdrawals by trace_id. It will assume there is only one payment

=cut

sub get_doughflow_withdrawal_amount_by_trace_id {
    my $self     = shift;
    my $trace_id = shift;

    my $payment = BOM::Database::AutoGenerated::Rose::Doughflow::Manager->get_doughflow(
        require_objects => ['payment'],
        query           => [
            account_id => $self->account->id,
            remark     => {like => '%trace_id=' . $trace_id . '%'},
            amount     => {le => 0}
        ],
        db => $self->db,
    );

    if ($payment) {
        return -1 * $payment->[0]->payment->amount;
    }
    return;
}

sub delete_expired_tokens {
    my $self = shift;

    my $sql = q{ DELETE FROM betonmarkets.handoff_token WHERE client_loginid = ? and expires < NOW() };
    return $self->db->dbic->run(
        ping => sub {
            my $sth = $_->prepare($sql);
            return $sth->execute($self->client_loginid);
        });
}

=head2 is_duplicate_payment

Check the trace_id, transaction_id of payments to find duplicate, used during doughflow validation

=cut

sub is_duplicate_payment {
    my $self = shift;
    my $args = shift;

    my $payment = BOM::Database::AutoGenerated::Rose::Doughflow::Manager->get_doughflow(
        require_objects => ['payment'],
        query           => [
            transaction_type => $args->{transaction_type},
            length($args->{transaction_id} // '')
            ? (
                or => [
                    trace_id       => $args->{trace_id},
                    transaction_id => $args->{transaction_id}])
            : (
                trace_id => $args->{trace_id},
            ),
            $args->{payment_processor} ? (payment_processor => $args->{payment_processor}) : (),
        ],
        db => $self->db,
    );
    if (scalar @{$payment}) {
        return 1;
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

=head1 NAME

BOM::Database::DataMapper::Payment::DoughFlow

=head1 SYNOPSIS

This is a class that will collect legacy payment. payment subrotines that are not defined in here will return the results by joining them with legacy_payment table so they will become queries about legacy_payment only.

=head1 VERSION

0.1

=head1 AUTHOR

RMG Company

=cut
