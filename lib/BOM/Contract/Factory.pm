package BOM::Contract::Factory;

use v5.26;
use warnings;

use BOM::Contract;
use BOM::Product::ContractFactory;
use Exporter qw(import);

our @EXPORT_OK = qw(produce_contract);

=head2 produce_contract

method creates a new BOM::Contract object based on provided parameters. See
documentation for C<BOM::Product::ContractFactory::produce_contract> for
details regarding parameters.

=cut

sub produce_contract {
    my $contract = BOM::Product::ContractFactory::produce_contract(@_);
    return BOM::Contract->new(inner_contract => $contract);
}

1;
