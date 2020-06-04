package BOM::ContractInfo;

use strict;
use warnings;

use Syntax::Keyword::Try;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Transaction::Utility;
use Finance::Contract::Longcode qw(shortcode_to_parameters);
use BOM::Backoffice::Request;

# Get:
#    description - typical description printed on statement/profit_table.
#    longcode - longcode of the contract.
#    is_legacy_contract - if the contract is a legacy contract.
#    indicative_price - indicative sell price for the contract if the contract was still open.

sub get_info {
    my $fmb      = shift;
    my $currency = shift;

    my $info = {};
    $info->{contract} = $fmb;
    if ($fmb->{bet_class} eq 'legacy_bet') {
        $info->{is_legacy} = 1;
    } else {
        try {
            my $contract_parameters = shortcode_to_parameters($fmb->{short_code}, $currency);
            $contract_parameters->{limit_order} = BOM::Transaction::Utility::extract_limit_orders($fmb) if $fmb->{bet_class} eq 'multiplier';
            my $contract = produce_contract($contract_parameters);
            $info->{longcode} = BOM::Backoffice::Request::localize($contract->longcode);
            if (not $fmb->{is_sold}) {
                if ($contract and $contract->may_settle_automatically) {
                    $info->{indicative_price} = $contract->bid_price;
                }
            }
        }
        catch {
            $info->{is_legacy} = 1;
        }
    }

    my $description;
    BOM::Backoffice::Request::template()->process('backoffice/contract_desc.html.tt', $info, \$description)
        || die BOM::Backoffice::Request::template()->error(), "\n";

    $info->{description} = $description;
    return $info;
}

1;
