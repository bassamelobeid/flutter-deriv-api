package BOM::RPC::v3::PortfolioManagement;

use strict;
use warnings;

use Date::Utility;
use Try::Tiny;

use BOM::RPC::v3::Utility;
use BOM::RPC::v3::Contract;
use BOM::Product::ContractFactory qw(simple_contract_info);
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Platform::Context qw (request localize);
use BOM::Product::Transaction;

sub portfolio {
    my $params = shift;

    my $client = $params->{client};

    my $portfolio = {contracts => []};
    return $portfolio unless $client;

    _sell_expired_contracts($client, $params->{source});

    foreach my $row (@{__get_open_contracts($client)}) {
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
            longcode       => (simple_contract_info($row->{short_code}, $client->currency))[0] // '',
            app_idi        => $row->{source},
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

    my $client = $params->{client};
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

    my $client = $params->{client};

    my @fmbs = ();

    if (my $contract_id = $params->{args}->{contract_id}) {
        @fmbs = @{__get_contract_details_by_id($client, $contract_id)};
        if (scalar @fmbs and $fmbs[0]->{account_id} ne $client->default_account->id) {
            @fmbs = ();
        }
    } else {
        @fmbs = @{__get_open_contracts($client)};
    }

    my $response = {};
    if (scalar @fmbs > 0) {
        foreach my $fmb (@fmbs) {
            my $id = $fmb->{id};
            my $sell_time;
            $sell_time = Date::Utility->new($fmb->{sell_time})->epoch if $fmb->{sell_time};
            my $bid = BOM::RPC::v3::Contract::get_bid({
                short_code  => $fmb->{short_code},
                contract_id => $id,
                currency    => $client->currency,
                is_sold     => $fmb->{is_sold},
                sell_time   => $sell_time
            });
            if (exists $bid->{error}) {
                $response->{$id} = $bid;
            } else {
                my $transaction_ids = {buy => $fmb->{buy_transaction_id}};
                $transaction_ids->{sell} = $fmb->{sell_transaction_id} if ($fmb->{sell_transaction_id});

                $response->{$id} = {
                    transaction_ids => $transaction_ids,
                    buy_price       => $fmb->{buy_price},
                    purchase_time   => Date::Utility->new($fmb->{purchase_time})->epoch,
                    account_id      => $fmb->{account_id},
                    is_sold         => $fmb->{is_sold},
                    $sell_time ? (sell_time => $sell_time) : (),
                    defined $fmb->{sell_price}
                    ? (sell_price => sprintf('%.2f', $fmb->{sell_price}))
                    : (),
                    %$bid
                };
            }
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
