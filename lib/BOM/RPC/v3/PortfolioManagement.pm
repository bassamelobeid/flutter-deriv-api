package BOM::RPC::v3::PortfolioManagement;

use strict;
use warnings;

use Date::Utility;
use Try::Tiny;

use Price::Calculator qw/get_formatting_precision/;

use BOM::RPC::v3::Utility;
use BOM::Platform::Pricing;
use BOM::RPC::v3::Accounts;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Platform::Context qw (request localize);
use BOM::Transaction;

sub portfolio {
    my $params = shift;

    my $client = $params->{client};

    my $portfolio = {contracts => []};
    return $portfolio unless $client;

    _sell_expired_contracts($client, $params->{source});

    my @rows = @{__get_open_contracts($client)};
    return $portfolio unless scalar @rows > 0;

    my @short_codes = map { $_->{short_code} } @rows;

    my $res = BOM::Platform::Pricing::call_rpc(
        'longcode',
        {
            short_codes => \@short_codes,
            currency    => $client->currency,
            language    => $params->{language},
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
}

sub __get_open_contracts {
    my $client = shift;

    my $clientdb = BOM::Database::ClientDB->new({
        client_loginid => $client->loginid,
        operation      => 'replica',
    });

    return $clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', [$client->loginid, $client->currency, 'false']);

}

sub sell_expired {
    my $params = shift;

    my $client = $params->{client};
    return _sell_expired_contracts($client, $params->{source});
}

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

sub proposal_open_contract {
    my $params = shift;

    my $client = $params->{client};

    my @fmbs = ();

    if (my $contract_id = $params->{args}->{contract_id}) {
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
        my $bid = BOM::Platform::Pricing::call_rpc(
            'get_bid',
            {
                short_code            => $fmb->{short_code},
                contract_id           => $id,
                currency              => $currency,
                is_sold               => $fmb->{is_sold},
                sell_time             => $sell_time,
                sell_price            => $fmb->{sell_price},
                buy_price             => $fmb->{buy_price},
                app_markup_percentage => $params->{app_markup_percentage},
                landing_company       => $lc_name,
            });
        if (exists $bid->{error}) {
            $response->{$id} = $bid;
        } else {
            my $transaction_ids = {buy => $fmb->{buy_transaction_id}};
            $transaction_ids->{sell} = $fmb->{sell_transaction_id} if ($fmb->{sell_transaction_id});

            # ask_price doesn't make any sense for contract that are already bought or sold
            delete $bid->{ask_price};

            $bid->{transaction_ids} = $transaction_ids;
            $bid->{buy_price}       = $fmb->{buy_price};
            $bid->{purchase_time}   = Date::Utility->new($fmb->{purchase_time})->epoch;
            $bid->{account_id}      = $fmb->{account_id};
            $bid->{is_sold}         = $fmb->{is_sold};
            $bid->{sell_time}       = $sell_time if $sell_time;
            $bid->{sell_price}      = sprintf('%' . get_formatting_precision($currency) . 'f', $fmb->{sell_price}) if defined $fmb->{sell_price};

            $response->{$id} = $bid;
        }
    }
    return $response;
}

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
