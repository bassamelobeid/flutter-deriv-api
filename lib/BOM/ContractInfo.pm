package BOM::ContractInfo;

use Date::Utility;
use BOM::Product::ContractFactory qw( simple_contract_info produce_contract);
use BOM::Platform::Context;


### get_info
#
# Syntatic sugar for getting information about a contract with record from fmb table.
#
# my $info = BOM::ContractInfo::get_info( $fmb, $currency );
#
# Gets informations such as
#    description - typical description printed on statement/profit_table.
#    longcode - longcode of the contract.
#    analyze_link - analyze link for the contract.
#    is_legacy_contract - if the contract is a legacy contract.
#    indicative_price - indicative sell price for the contract if the contract was still open.
#
###
sub get_info {
    my $fmb            = shift;
    my $currency       = shift;
    my $bo_client      = shift;    # for backoffice we need to pass client loginid
    my $is_transaction = shift;

    my $info = {};
    $info->{contract} = $fmb;
    if ($fmb->{bet_class} eq 'legacy_bet') {
        $info->{is_legacy} = 1;
    } else {
        try {
            my ($longcode, $is_tick_expiry, $is_spread_bet) = simple_contract_info($fmb->{short_code}, $currency);
            $info->{longcode} = $longcode;
            my ($recomputed_price, $sell_price, $soldearly_datetime, $is_expired);
            if ($fmb->{is_sold}) {
                $recomputed_price = $fmb->{'sell_price'};
                # spread bet doesn't have payout_price
                if ($is_spread_bet or $fmb->{'payout_price'} != $fmb->{'sell_price'}) {
                    $sell_price         = $fmb->{'sell_price'};
                    $soldearly_datetime = Date::Utility->new($fmb->{'sell_time'})->epoch;
                }
                $is_expired = 1;
            } else {
                my $contract = produce_contract($fmb->{short_code}, $currency);
                if ($contract and $contract->may_settle_automatically) {
                    $recomputed_price = $contract->bid_price;
                    $info->{indicative_price} = $contract->bid_price unless $contract->is_spread;
                }
                $is_expired = 1 if $contract->is_expired;
            }

            $info->{analyse_link} =
                get_analyse_link($is_transaction ? $fmb->{financial_market_bet_id} : $fmb->{id}, $bo_client);
        }
        catch {
            $info->{is_legacy} = 1;
        }
    }

    my $description;
    BOM::Platform::Context::template()->process('bet/description.html.tt', $info, \$description)
        || die BOM::Platform::Context::template()->error(), "\n";

    $info->{description} = $description;
    return $info;
}

sub get_analyse_link {
    my $contract_id = shift;
    my $bo_client   = shift;

    my $template_parameters = {contract_id => $contract_id};
    if ($bo_client) {
        $template_parameters->{bo_client} = $bo_client;
    }

    my $analyse_link;
    BOM::Platform::Context::template()->process('bet/analyse_link.html.tt', $template_parameters, \$analyse_link)
        || die BOM::Platform::Context::template()->error(), "\n";
    return $analyse_link;
}

