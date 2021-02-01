package BOM::RPC::v3::PortfolioManagement;

use strict;
use warnings;

use Date::Utility;
use Syntax::Keyword::Try;
use Format::Util::Numbers qw/formatnumber roundcommon/;
use List::Util qw/none/;

use BOM::RPC::Registry '-dsl';

use BOM::RPC::v3::Utility qw(longcode log_exception);
use BOM::RPC::v3::Accounts;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Platform::Context qw (request localize);
use BOM::Config::Runtime;
use BOM::Transaction;
use BOM::Transaction::Utility;
use BOM::Pricing::v3::Contract;

requires_auth('trading');

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
    my $client    = $params->{client} or return $portfolio;

    _sell_expired_contracts($client, $params->{source});

    my @rows = @{__get_open_contracts($client)} or return $portfolio;

    my @short_codes = map { $_->{short_code} } @rows;

    my $res = longcode({
        short_codes => \@short_codes,
        currency    => $client->currency,
        language    => $params->{language},
        source      => $params->{source},
    });

    my $contract_type = $params->{args}->{contract_type};

    foreach my $row (@rows) {

        next if $contract_type && scalar(@$contract_type) && none { $_ eq $row->{bet_type} } @$contract_type;

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
    } catch {
        log_exception();
        $response = BOM::RPC::v3::Utility::create_error({
                code              => 'SellExpiredError',
                message_to_client => localize('There was an error processing the request.')});
    }

    return $response;
}

rpc proposal_open_contract => sub {
    my $params = shift;

    my $client = $params->{client};

    my @fmbs        = ();
    my $contract_id = $params->{contract_id} || $params->{args}->{contract_id};
    if ($contract_id) {
        @fmbs = @{get_contract_details_by_id($client, $contract_id)};
        if (not $client->default_account or scalar @fmbs and $fmbs[0]->{account_id} ne $client->default_account->id) {
            @fmbs = ();
        }
    } else {
        @fmbs = @{__get_open_contracts($client)};
    }
    return populate_proposal_open_contract_response($client, $params, \@fmbs);
};

=head2 populate_proposal_open_contract_response

Will populate a new `proposal_open_contract` response for
each of the contracts (contract_id or all the open contracts for this account id)
and return an object with the contract_id as key and the details of the contract as
response.

=cut

sub populate_proposal_open_contract_response {
    my ($client, $params, $fmbs) = @_;

    my $response = {};
    foreach my $fmb (@{$fmbs}) {
        my $id                  = $fmb->{id};
        my $contract_parameters = BOM::Transaction::Utility::build_contract_parameters($client, $fmb);

        my $contract = BOM::Pricing::v3::Contract::get_bid($contract_parameters);
        $response->{$id} = $contract;

        # set CONTRACT_PARAMS if we are subscribing to POC and the contract is not sold yet.
        if (not $contract->{error} and $params->{args}->{subscribe} and not $contract->{is_sold}) {
            BOM::Transaction::Utility::set_contract_parameters($contract_parameters);
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
