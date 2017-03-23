package BOM::ContractInfo;

use strict;
use warnings;

use Try::Tiny;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Backoffice::Request;
use BOM::Platform::Pricing;

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
            my $res = BOM::Platform::Pricing::call_rpc(
                'get_contract_details',
                {
                    short_code      => $fmb->{short_code},
                    currency        => $currency,
                    landing_company => $bo_client->landing_company->short,
                    language        => 'EN',
                });
            if (exists $res->{error}) {
                $info->{longcode} = 'Could not retrieve contract details';
            } else {
                $info->{longcode} = $res->{longcode};
            }

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
