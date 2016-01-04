package BOM::RPC::v3::PortfolioManagement;

use strict;
use warnings;

use Date::Utility;

use BOM::Product::ContractFactory qw(simple_contract_info);
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Platform::Client;
use BOM::Platform::Context qw (request);

sub portfolio {
    my $params = shift;

    BOM::Platform::Context::request()->language($params->{language});

    my $client;
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    }

    my $portfolio = {contracts => []};
    return $portfolio unless $client;

    foreach my $row (@{__get_open_contracts($client)}) {
        my %trx = (
            contract_id    => $row->{id},
            transaction_id => $row->{buy_id},
            purchase_time  => Date::Utility->new($row->{purchase_time})->epoch,
            symbol         => $row->{underlying_symbol},
            payout         => $row->{payout_price},
            buy_price      => $row->{buy_price},
            date_start     => Date::Utility->new($row->{start_time})->epoch,
            expiry_time    => Date::Utility->new($row->{expiry_time})->epoch,
            contract_type  => $row->{bet_type},
            currency       => $client->currency,
            shortcode      => $row->{short_code},
            longcode       => (simple_contract_info($row->{short_code}, $client->currency))[0] // '',
        );
        push $portfolio->{contracts}, \%trx;
    }

    return $portfolio,;
}

sub __get_open_contracts {
    my $client = shift;

    my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new({
            client_loginid => $client->loginid,
            currency_code  => $client->currency,
            db             => BOM::Database::ClientDB->new({
                    client_loginid => $client->loginid,
                    operation      => 'replica',
                }
            )->db,
        });

    return $fmb_dm->get_open_bets_of_account();
}

1;
