use strict;
use warnings;
use Test::More;

use BOM::Pricing::PriceDaemon;

my $subchannel      = "v1,AUD,10,stake,0,0.025,0.012,0.02,0.35,50000,,";
my $contract_params = {
    amount                => 10,
    amount_type           => "stake",
    app_markup_percentage => 0,
    base_commission       => "0.012",
    currency              => "AUD",
    deep_otm_threshold    => "0.025",
    min_commission_amount => "0.02",
    staking_limits        => {
        max => 50000,
        min => "0.35",
    },
};

is_deeply(
    $contract_params,
    BOM::Pricing::PriceDaemon::_deserialize_contract_parameters(undef, $subchannel),
    "proposal subchannel's are correctly deconstructed"
);

done_testing;
