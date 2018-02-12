package BOM::RPC::v3::PortfolioManagement;

use strict;
use warnings;

use Date::Utility;
use Try::Tiny;
use Format::Util::Numbers qw/formatnumber/;

use BOM::RPC::Registry '-dsl';

use BOM::RPC::v3::Utility;
use BOM::RPC::v3::Accounts;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Platform::Context qw (request localize);
use BOM::Platform::Runtime;
use BOM::Transaction;

requires_auth();

rpc portfolio => sub {
    my $params = shift;

    my $app_config = BOM::Platform::Runtime->instance->app_config;
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

    my $res = BOM::RPC::v3::Utility::longcode({
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
            purchase_time  => Date::Utility->new($row->{purchase_time})->epoch,
            symbol         => $row->{underlying_symbol},
            payout         => $row->{payout_price},
            buy_price      => $row->{buy_price},
            date_start     => Date::Utility->new($row->{start_time})->epoch,
            expiry_time    => Date::Utility->new($row->{expiry_time})->epoch,
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
        @fmbs = @{__get_contract_details_by_id($client, $contract_id)};
        if (not $client->default_account or scalar @fmbs and $fmbs[0]->{account_id} ne $client->default_account->id) {
            @fmbs = ();
        }
    } else {
        @fmbs = @{__get_open_contracts($client)};
    }

    my ($response, $currency, $lc_name) = ({}, $client->currency, $client->landing_company->short);
    foreach my $fmb (@fmbs) {
        my $id = $fmb->{id};
        my $sell_time;
        $sell_time = Date::Utility->new($fmb->{sell_time})->epoch if $fmb->{sell_time};
        my $bid = {
            short_code            => $fmb->{short_code},
            contract_id           => $id,
            currency              => $currency,
            is_expired            => $fmb->{is_expired},
            is_sold               => $fmb->{is_sold},
            buy_price             => $fmb->{buy_price},
            app_markup_percentage => $params->{app_markup_percentage},
            landing_company       => $lc_name,
            account_id            => $fmb->{account_id},
            purchase_time         => Date::Utility->new($fmb->{purchase_time})->epoch,
            country_code          => $client->residence,
        };
        my $transaction_ids = {buy => $fmb->{buy_transaction_id}};
        $transaction_ids->{sell} = $fmb->{sell_transaction_id} if ($fmb->{sell_transaction_id});

        $bid->{transaction_ids} = $transaction_ids;
        $bid->{sell_time}       = $sell_time if $sell_time;
        $bid->{sell_price}      = formatnumber('price', $currency, $fmb->{sell_price}) if defined $fmb->{sell_price};

        $response->{$id} = $bid;
    }
    return $response;
};

sub __get_contract_details_by_id {
    my $client      = shift;
    my $contract_id = shift;

    my $mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        broker_code => $client->broker_code,
        operation   => 'replica'
    });
    return $mapper->get_contract_details_with_transaction_ids($contract_id);
}

1;
