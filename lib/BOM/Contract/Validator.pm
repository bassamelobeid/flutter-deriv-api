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

=head2 is_valid_to_sell

Check the contract parameters and determine if the contract is valid for the
client to sell it back to us. Returns a tuple with first item being a boolean
indicating if the contract is valid to sell, and the second being the error
indicating the reason why the contract is not valid.

Accepts the following arguments:

=over 4

=item landing_company -- landing company from which the contract has been purchased

=item country_code -- the country in which the client resides

=item skip_barrier_validation -- indicates if barrier validation should be skipped

=back

=cut

sub is_valid_to_sell {
    my ($self, $contract, @args) = @_;
    my $valid = $contract->inner_contract->is_valid_to_sell(@args);
    return 1, undef if $valid;
    return 0, $contract->inner_contract->primary_validation_error;
}

=head2 is_legacy

Is legacy returns true if the contract is of a legacy type that is not supported any more.

=cut

sub is_legacy {
    my ($self, $contract) = @_;
    return $contract->inner_contract->is_legacy;
}

1;
