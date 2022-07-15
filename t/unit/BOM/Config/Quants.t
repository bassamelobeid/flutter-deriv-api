use strict;
use warnings;

no indirect;

use Test::More;
use Test::Fatal;
use Test::MockModule;
use Test::Warnings;

use BOM::Config;
use BOM::Config::Quants;

my $config_mock = Test::MockModule->new("BOM::Config");
$config_mock->redefine("quants" => {
    commission => {},
    default_stake => {},
    bet_limits => {
        min_payout => {
            default_landing_company => {
                default_market => {
                    default_contract_category => {
                        USD => 10,
                        EUR => 20,
                    }
                },
            },
            maltainvest => {
                synthetic => {
                    default_contract_category => {
                        AUD => 10,
                        EUR => 20,
                    }
                }
            }
        },
        max_payout => {
            default_landing_company => {
                default_market => {
                    default_contract_category => {
                        USD => 90,
                        EUR => 30,
                    }
                }
            },
            maltainvest => {
                synthetic => {
                    default_contract_category => {
                        AUD => 95,
                        EUR => 20,
                    }
                }
            }
        },
        max_stake => {
            default_landing_company => {
                default_market => {
                    default_contract_category => {
                        USD => 40,
                        EUR => 50,
                    }
                }
            },
            maltainvest => {
                synthetic => {
                    default_contract_category => {
                        AUD => 45,
                        EUR => 20,
                    }
                }
            }
        },
        min_stake => {
            default_landing_company => {
                default_market => {
                    default_contract_category => {
                        USD => 60,
                        EUR => 70,
                    }
                }
            },
            maltainvest => {
                synthetic => {
                    default_contract_category => {
                        AUD => 65,
                        EUR => 20,
                    }
                }
            }
        }
    }
});

subtest 'minimum_payout_limit ' => sub {

    is BOM::Config::Quants::minimum_payout_limit("USD","defaul","default_market","default_contract_category") , 10 , "default arguments are passed";
    is BOM::Config::Quants::minimum_payout_limit("AUD","maltainvest","synthetic","default_contract_category") , 10 , 'non-default arguments are passed';
    Test::Warnings::allow_warnings(1);
    is BOM::Config::Quants::minimum_payout_limit() , undef , "no arguments return undef";
    is BOM::Config::Quants::minimum_payout_limit("ABS") , undef, "unsupported currency returns undef";
    Test::Warnings::allow_warnings(0);
 
};

subtest 'maximum_payout_limit' => sub {
    is BOM::Config::Quants::maximum_payout_limit("USD","default_market","default_contract_category") , 90 , "correct arguments are passed";
    is BOM::Config::Quants::maximum_payout_limit("AUD","maltainvest","synthetic","default_contract_category") , 95 , 'non-default arguments are passed';
    Test::Warnings::allow_warnings(1);
    is BOM::Config::Quants::minimum_payout_limit() , undef , "no arguments return undef";
    is BOM::Config::Quants::minimum_payout_limit("ABS") , undef, "unsupported currency returns undef";
    Test::Warnings::allow_warnings(0);
};

subtest 'maximum_stake_limit' => sub {
    is BOM::Config::Quants::maximum_stake_limit("USD","default_market","default_contract_category") , 40 , "correct arguments are passed";
    is BOM::Config::Quants::maximum_stake_limit("AUD","maltainvest","synthetic","default_contract_category") , 45 , 'non-default arguments are passed';
    Test::Warnings::allow_warnings(1);
    is BOM::Config::Quants::maximum_stake_limit() , undef , "no arguments return undef";
    is BOM::Config::Quants::minimum_payout_limit("ABS") , undef, "unsupported currency returns undef";
    Test::Warnings::allow_warnings(0);
};

subtest  'minimum_stake_limit' => sub {
    is BOM::Config::Quants::minimum_stake_limit("USD","default_market","default_contract_category") , 60 , "correct arguments are passed";
    is BOM::Config::Quants::minimum_stake_limit("AUD","maltainvest","synthetic","default_contract_category") , 65 , 'non-default arguments are passed';
    Test::Warnings::allow_warnings(1);
    is BOM::Config::Quants::minimum_stake_limit() , undef, "no arguments return undef";
    is BOM::Config::Quants::minimum_payout_limit("ABS") , undef, "unsupported currency returns undef";
    Test::Warnings::allow_warnings(0);
};

subtest 'market_pricing_limit' => sub {
   is 1 , 1, 'sample'; 
};

$config_mock->unmock_all();

done_testing;
