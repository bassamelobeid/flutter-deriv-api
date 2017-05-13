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
    # we have to allow a match on the same loginid since for withdrawals, we first create a record in here and then proceed with further processing, which includes a call here ;-)
    # in at least the test environment, we may not have a {'client_logind'} class property, so we will accept an optional key in the $args
    my $loginid = $self->{'client_loginid'} || $args->{'client_loginid'} || die "We need a loginid in order to properly check for a dupe";
    # Adding coalesce on loginid since we would never match on NULL and I'm not sure that the value will always be there... A NOT NULL constraint on that table column would do it, but have to save that for another day.
    my ($payment) = $self->db->dbh->selectrow_array('SELECT TRUE FROM payment.cryptocurrency WHERE address = ? AND currency_code = ? AND COALESCE(loginid, '') != ?', undef, $args->{'address'}, $self->{'currency_code'}, $loginid);
    return $payment;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

=head1 NAME

BOM::Database::DataMapper::Payment::CryptoCurrency

=cut
