package BOM::RPC::v3::PortfolioManagement;

use strict;
use warnings;

use Date::Utility;
use Try::Tiny;

use BOM::RPC::v3::Utility;
use BOM::Product::ContractFactory qw(simple_contract_info);
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Platform::Client;
use BOM::Platform::Context qw (request localize);
use BOM::Product::Transaction;

sub portfolio {
    my $params = shift;

    BOM::Platform::Context::request()->language($params->{language});

    my $client;
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    }

    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    my $portfolio = {contracts => []};
    return $portfolio unless $client;

    _sell_expired_contracts($client, $params->{source});

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

sub sell_expired {
    my $params = shift;

    my $client;
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    }

    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    return _sell_expired_contracts($client, $params->{source});
}

sub _sell_expired_contracts {
    my ($client, $source) = @_;

    my $response = {count => 0};

    try {
        my $res = BOM::Product::Transaction::sell_expired_contracts({
            client => $client,
            source => $source,
        });
        $response->{count} = $res->{number_of_sold_bets} if ($res and exists $res->{number_of_sold_bets});
    }
    catch {
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'SellExpiredError',
                message_to_client => localize('There was an error processing the request.')});
    };

    return $response;
}

sub proposal_open_contract {
    my $params = shift;

    my $client;
    if ($params->{client_loginid}) {
        $client = BOM::Platform::Client->new({loginid => $params->{client_loginid}});
    }

    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    my @fmbs    = ();
    my $account = $client->default_account;
    if ($params->{contract_id}) {
        @fmbs = @{$account->find_financial_market_bet(query => [id => $params->{contract_id}])}
            if $account;
    } else {
        @fmbs = @{__get_open_contracts($client)};
    }

    my $response = {};
    if (scalar @fmbs > 0) {
        foreach my $fmb (@fmbs) {
            my $id = $fmb->{id};
            $response->{$id} = {
                short_code => $fmb->{short_code},
                currency   => $client->currency,
                underlying => $fmb->{underlying_symbol},
                buy_price  => $fmb->{buy_price},
                sell_price => $fmb->{sell_price},
                is_expired => $fmb->{is_expired}};
        }
    }

    return $response;
}

1;
