package BOM::RPC::v3::PortfolioManagement;

use strict;
use warnings;

use Date::Utility;
use Syntax::Keyword::Try;
use Format::Util::Numbers qw/formatnumber roundcommon/;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use List::Util qw/none/;

use BOM::RPC::Registry '-dsl';

use BOM::RPC::v3::Utility qw(longcode log_exception);
use BOM::RPC::v3::Accounts;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Platform::Context qw (request localize);
use BOM::Config::Runtime;
use BOM::Transaction;
use BOM::Pricing::v3::Contract;
use BOM::Pricing::v3::Utility;

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
    if (not $client->default_account) {
        return {};    # empty response
    }

    my $landing_company    = $client->landing_company->short;
    my $account_id         = $client->default_account->id;
    my $contract_id        = $params->{contract_id} || $params->{args}->{contract_id};
    my $poc_parameters_all = {};
    if (defined $contract_id) {
        my $fmb = get_contract_details_by_id($client, $contract_id)->[0];

        # In special case that 'proposal_open_contract' with contract_id is called immediately after 'buy',
        # we could get an undefined $fmb result, because of DB replication delay.
        if (defined $fmb and $fmb->{account_id} eq $account_id) {
            $poc_parameters_all->{$fmb->{id}} = BOM::Transaction::Utility::build_poc_parameters($client, $fmb);
        }
        # In case of db replication delay, we get poc_parameters from pricer_shared_redis.
        elsif (not defined $fmb) {
            my $poc_parameters = BOM::Pricing::v3::Utility::get_poc_parameters($contract_id, $landing_company);
            $poc_parameters_all->{$contract_id} = $poc_parameters if (%$poc_parameters);
        }
    } else {
        for my $fmb (@{__get_open_contracts($client)}) {
            $poc_parameters_all->{$fmb->{id}} = BOM::Transaction::Utility::build_poc_parameters($client, $fmb);
        }
    }

    my $response = {};

    if ($params->{args}->{subscribe} && (!defined $contract_id || defined $poc_parameters_all->{$contract_id})) {
        # subscription channel for either all open contracts ('*'), or a specific open contract.
        $response->{channel} = join '::', 'CONTRACT_PRICE', $landing_company, $account_id, ($contract_id // '*');
    }

    for my $poc_parameters (values %$poc_parameters_all) {
        my $res = BOM::Pricing::v3::Contract::get_bid($poc_parameters);
        $response->{$poc_parameters->{contract_id}} = $res;

        if (defined $contract_id && defined $res->{error}) {
            return $res;
        }

        if (not $res->{error} and $response->{channel} and not $res->{is_sold}) {
            BOM::Transaction::Utility::set_poc_parameters($poc_parameters);
            my $pricer_args = BOM::Transaction::Utility::build_poc_pricer_args($poc_parameters);

            # pass the pricer_args key to be set by websocket
            push @{$response->{pricer_args_keys}}, $pricer_args;
        }
    }

    # if we are subscribing to a specific contract_id, but it was already sold, do not send back a channel name.
    if (defined $contract_id && $response->{channel} && !defined $response->{pricer_args_keys}) {
        delete $response->{channel};
    }
    return $response;
};

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
