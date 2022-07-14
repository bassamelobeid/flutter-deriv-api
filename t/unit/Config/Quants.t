use strict;
use warnings;

no indirect;

use Test::More;
use Test::Fatal;
use Test::MockModule;

use BOM::Config;
use BOM::Config::Quants;


subtest 'minimum_stake_limit - min_stake is fetched' => sub {
    my $config_mock = Test::MockModule->new("BOM::Config");
    $config_mock->redefine("quants" => {
        commission => {

        },
        default_stake => {

        },
        bet_limits => {
            min_payout => {
                default_landing_company => {
                    default_market => {
                        default_contract_category => {
                            USD => 10,
                            EUR => 20,
                        }
                    }
                }
            }
        }
    });

    is BOM::Config::Quants::minimum_payout_limit("USD","default_market","default_contract_category") , 10 , "Fields are correctly accessed";
    $config_mock->unmock_all();
};


done_testing();
