package BOM::Contract::Validator;

use v5.26;
use warnings;

=head2 is_valid_to_buy

Check the contract parameters and determine if the contract is valid for the
client to buy it. Returns a tuple with first item being a boolean indicating if
the contract is valid, and the second being the error if the contract is not
valid.

=cut

sub is_valid_to_buy {
    my ($self, $contract, @args) = @_;
    my $valid = $contract->inner_contract->is_valid_to_buy(@args);
    return 1, undef if $valid;
    return 0, $contract->inner_contract->primary_validation_error;
}

1;
