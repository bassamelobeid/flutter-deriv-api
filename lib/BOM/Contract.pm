package BOM::Contract;

use v5.26;
use warnings;

use Moose;

=head2 inner_contract

reference to C<BOM::Product::Contract> object that this BOM::Contract object
wraps. Long term goal is not to have it, if you use it anywhere outside of
C<bom> repo you need to think about refactoring your code. The name
C<inner_contract> is specifically chosen to enable you to quickly find the
places in the code that require refactoring.

=cut

has inner_contract => (
    is       => 'ro',
    required => 1,
);

=head2 metadata

Returns contract metadata as a hashref. Includes the following fields:

=over 4

=item contract_category

=item underlying_symbol

=item barrier_category 

=item expiry_type      

=item start_type       

=item contract_duration

=item for_sale         

=item contract_type    

=item market           

=back

=cut

sub metadata {
    my ($self, @args) = @_;
    return $self->inner_contract->metadata(@args);
}

=head2 longcode

returns textual description of the contract. The value needs to be passed to
C<BOM::Platform::Context::localize> before it can be forwarded to users as it
is not a string.

=cut

sub longcode {
    return shift->inner_contract->longcode;
}

=head2 is_expired

returns true if the contract has expired

=cut

sub is_expired {
    return shift->inner_contract->is_expired;
}

no Moose;

__PACKAGE__->meta->make_immutable;

1;
