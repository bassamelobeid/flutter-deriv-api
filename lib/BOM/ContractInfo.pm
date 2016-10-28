package BOM::ContractInfo;

use strict;
use warnings;

use Try::Tiny;
use BOM::Product::ContractFactory qw( simple_contract_info produce_contract );
use BOM::Backoffice::Request;

# Get:
#    description - typical description printed on statement/profit_table.
#    longcode - longcode of the contract.
#    is_legacy_contract - if the contract is a legacy contract.
#    indicative_price - indicative sell price for the contract if the contract was still open.

sub get_info {
    my $fmb            = shift;
    my $currency       = shift;
    my $bo_client      = shift;
    my $is_transaction = shift;

    my $info = {};
    $info->{contract} = $fmb;
    if ($fmb->{bet_class} eq 'legacy_bet') {
        $info->{is_legacy} = 1;
    } else {
        try {
            my ($longcode, undef, undef) =
                simple_contract_info($fmb->{short_code}, $currency);

            $info->{longcode} = $longcode;

            if (not $fmb->{is_sold}) {
                my $contract = produce_contract($fmb->{short_code}, $currency);
                if ($contract and $contract->may_settle_automatically) {
                    $info->{indicative_price} = $contract->bid_price
                        unless $contract->is_spread;
                }
            }
        }
        catch {
            $info->{is_legacy} = 1;
        };
    }

    my $description;
    BOM::Backoffice::Request::template()->process('backoffice/contract_desc.html.tt', $info, \$description)
        || die BOM::Backoffice::Request::template()->error(), "\n";

    $info->{description} = $description;
    return $info;
}

1;
