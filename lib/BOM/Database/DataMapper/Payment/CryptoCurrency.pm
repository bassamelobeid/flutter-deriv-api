package BOM::Database::DataMapper::Payment::CryptoCurrency;

use Moose;
extends 'BOM::Database::DataMapper::Payment';

has '_mapper_required_objects' => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    init_arg => undef,
    default  => sub { return ['cryptocurrency'] },
);

=item is_duplicate_payment

Check the trace_id, transaction_id of payments to find duplicate, used during CTC validation

=cut

sub is_duplicate_payment {
    my $self = shift;
    my $args = shift;

    # transaction id should be unique since it's BTC address
    my ($payment) = $self->db->dbh->selectrow_array('SELECT TRUE FROM payment.cryptocurrency WHERE address = ? AND currency_code = ?', undef, $args->{'address'}, $self->{currency_code});
    return $payment;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

=head1 NAME

BOM::Database::DataMapper::Payment::CryptoCurrency

=cut
