package BOM::RPC::v3::PortfolioManagement;

use strict;
use warnings;

use Date::Utility;
use Try::Tiny;
use Format::Util::Numbers qw/formatnumber roundcommon/;

use BOM::RPC::Registry '-dsl';

use BOM::RPC::v3::Utility qw(longcode);
use BOM::RPC::v3::Accounts;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Platform::Context qw (request localize);
use BOM::Config::Runtime;
use BOM::Transaction;
use BOM::Pricing::v3::Contract;

requires_auth();

rpc "portfolio",
    category => 'account',
    sub {
    my $params = shift;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    if ($app_config->system->suspend->expensive_api_calls) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'SuspendedDueToLoad',
                message_to_client => localize(
                    'The system is currently under heavy load, and this call has been suspended temporarily. Please try again in a few minutes.')}
            ),
            ;
    }

    my $portfolio = {contracts => []};
    my $client = $params->{client} or return $portfolio;

    _sell_expired_contracts($client, $params->{source});

    my @rows = @{__get_open_contracts($client)} or return $portfolio;

    my @short_codes = map { $_->{short_code} } @rows;

    my $res = longcode({
        short_codes => \@short_codes,
        currency    => $client->currency,
        language    => $params->{language},
        source      => $params->{source},
    });

    foreach my $row (@rows) {

        my $longcode;
        if (!$res->{longcodes}->{$row->{short_code}}) {
            $longcode = localize('Could not retrieve contract details');
        } else {
            # this should already be localized
            $longcode = $res->{longcodes}->{$row->{short_code}};
        }

        my %trx = (
            contract_id    => $row->{id},
            transaction_id => $row->{buy_transaction_id},
            purchase_time  => 0 + Date::Utility->new($row->{purchase_time})->epoch,
            symbol         => $row->{underlying_symbol},
            payout         => $row->{payout_price},
            buy_price      => $row->{buy_price},
            date_start     => 0 + Date::Utility->new($row->{start_time})->epoch,
            expiry_time    => 0 + Date::Utility->new($row->{expiry_time})->epoch,
            contract_type  => $row->{bet_type},
            currency       => $client->currency,
            shortcode      => $row->{short_code},
            longcode       => $longcode,
            app_id         => BOM::RPC::v3::Utility::mask_app_id($row->{source}, $row->{purchase_time}));
        push @{$portfolio->{contracts}}, \%trx;
    }

    return $portfolio;
    };

sub __get_open_contracts {
    my $client = shift;

    my $clientdb = BOM::Database::ClientDB->new({
        client_loginid => $client->loginid,
        operation      => 'replica',
    });

    return $clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', [$client->loginid, $client->currency, 'false']);

}

rpc sell_expired => sub {
    my $params = shift;

    my $client = $params->{client};
    return _sell_expired_contracts($client, $params->{source});
};

sub _sell_expired_contracts {
    my ($client, $source) = @_;

    my $response = {count => 0};

    try {
        my $res = BOM::Transaction::sell_expired_contracts({
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

rpc proposal_open_contract => sub {
    my $params = shift;

    my $client = $params->{client};

    my @fmbs = ();
    my $contract_id = $params->{contract_id} || $params->{args}->{contract_id};
    if ($contract_id) {
        @fmbs = @{get_contract_details_by_id($client, $contract_id)};
        if (not $client->default_account or scalar @fmbs and $fmbs[0]->{account_id} ne $client->default_account->id) {
            @fmbs = ();
        }
    } else {
        @fmbs = @{__get_open_contracts($client)};
    }
    return populate_response_proposal_contract($client, $params, \@fmbs);
};

=head2 populate_response_proposal_contract

Will populate a new `proposal_open_contract` response for
each of the contracts (contract_id or all the open contracts for this account id)
and return an object with the contract_id as key and the details of the contract as
response.

=cut

sub populate_response_proposal_contract {
    my ($client, $params, $contract_details) = @_;

    my $response = {};
    foreach my $fmb (@{$contract_details}) {
        my $id = $fmb->{id};
        my $sell_time;
        my $is_sold = $fmb->{is_sold} ? 1 : 0;    #change value from a JSON::PP::Boolean to just 1 or 0  as per API Docs
        $sell_time = 0 + Date::Utility->new($fmb->{sell_time})->epoch if $fmb->{sell_time};
        my $contract = {
            short_code            => $fmb->{short_code},
            contract_id           => $id,
            currency              => $client->currency,
            is_expired            => $fmb->{is_expired},
            is_sold               => $is_sold,
            sell_price            => $fmb->{sell_price},
            buy_price             => $fmb->{buy_price},
            app_markup_percentage => $params->{app_markup_percentage},
            landing_company       => $client->landing_company->short,
            account_id            => $fmb->{account_id},
            country_code          => $client->residence,
            expiry_time           => 0 + Date::Utility->new($fmb->{expiry_time})->epoch,
        };

        $contract->{limit_order} = BOM::Transaction::extract_limit_orders($fmb) if $fmb->{bet_class} eq 'multiplier';
        $contract->{sell_time} //= $sell_time;

        $contract = BOM::Pricing::v3::Contract::get_bid($contract);
        if ($contract->{error}) {
            $response->{$id} = $contract;
        } else {
            my $transaction_ids = {buy => $fmb->{buy_transaction_id}};
            $transaction_ids->{sell} = $fmb->{sell_transaction_id} if ($fmb->{sell_transaction_id});

            $contract->{purchase_time}   = 0 + Date::Utility->new($fmb->{purchase_time})->epoch;
            $contract->{transaction_ids} = $transaction_ids;
            $contract->{buy_price}       = $fmb->{buy_price};
            $contract->{account_id}      = $fmb->{account_id};
            $contract->{is_sold}         = $is_sold;
            $contract->{sell_time}       = 0 + $sell_time if $sell_time;
            $contract->{sell_price}      = formatnumber('price', $client->currency, $fmb->{sell_price}) if defined $fmb->{sell_price};

            if (defined $contract->{buy_price} and (defined $contract->{bid_price} or defined $contract->{sell_price})) {
                $contract->{profit} =
                    (defined $contract->{sell_price})
                    ? formatnumber('price', $client->currency, $contract->{sell_price} - $contract->{buy_price})
                    : formatnumber('price', $client->currency, $contract->{bid_price} - $contract->{buy_price});
                $contract->{profit_percentage} = roundcommon(0.01, $contract->{profit} / $contract->{buy_price} * 100);
            }
            $response->{$id} = $contract;

            # if we're subscribing to proposal_open_contract and contract is not sold, then set CONTRACT_PARAMS here
            BOM::Pricing::v3::Utility::set_contract_parameters($contract, $client) if $params->{args}->{subscribe} and not $is_sold;
        }
    }

    return $response;

}

=head2 get_contract_details_by_id

With the contract_id will retrieve from clientdb `bet.financial_market_bet`
what are the transactions and details of this contract.

=cut

sub get_contract_details_by_id {
    my ($client, $contract_id) = @_;

    my $mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        broker_code => $client->broker_code,
        operation   => 'replica'
    });
    return $mapper->get_contract_details_with_transaction_ids($contract_id);
}

1;
