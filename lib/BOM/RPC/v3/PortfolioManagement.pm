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
use BOM::Platform::Client;
use BOM::Platform::Context qw (request localize);
use BOM::Product::Transaction;

sub portfolio {
    my $params = shift;

    my $token_details = BOM::RPC::v3::Utility::get_token_details($params->{token});
    return BOM::RPC::v3::Utility::invalid_token_error() unless $token_details->{loginid};

    my $client = BOM::Platform::Client->new({loginid => $token_details->{loginid}});
    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    my $portfolio = {contracts => []};
    return $portfolio unless $client;

    _sell_expired_contracts($client, $params->{source});

    foreach my $row (@{__get_open_contracts($client)}) {
        my %trx = (
            contract_id    => $row->{id},
            transaction_id => $row->{transaction_id},
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

    my $token_details = BOM::RPC::v3::Utility::get_token_details($params->{token});
    return BOM::RPC::v3::Utility::invalid_token_error() unless ($token_details and exists $token_details->{loginid});

    my $client = BOM::Platform::Client->new({loginid => $token_details->{loginid}});
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

    my $token_details = BOM::RPC::v3::Utility::get_token_details($params->{token});
    return BOM::RPC::v3::Utility::invalid_token_error() unless ($token_details and exists $token_details->{loginid});

    my $client = BOM::Platform::Client->new({loginid => $token_details->{loginid}});
    if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
        return $auth_error;
    }

    my @fmbs = ();

    # this flag is to tell whether to club both buy sell fmb record
    # don't want to place logic in FinancialMarketBet as thats only for query
    # we need to pass transaction_ids => [ {buy => 123}, {sell => 456} ] in case
    # client request by contract id else we send all open contracts so no need to club
    # in that case
    my $club_records = 1;
    if ($params->{contract_id}) {
        @fmbs = @{__get_contract_details_by_id($client, $params->{contract_id})};
        if (scalar @fmbs and $fmbs[0]->{account_id} ne $client->default_account->id) {
            @fmbs = ();
        }
    } else {
        @fmbs         = @{__get_open_contracts($client)};
        $club_records = 0;
    }

    my $response = {};
    if (scalar @fmbs > 0) {
        my @records = ();
        my $record = {transaction_ids => []};

        # populate transaction_ids as transaction_ids => [ {buy => 123}, {sell => 456} ]
        foreach my $fmb (@fmbs) {
            foreach my $column (keys %$fmb) {
                if ($column eq 'action_type') {
                    push $record->{transaction_ids}, {$fmb->{action_type} => $fmb->{transaction_id}};
                } else {
                    $record->{$column} = $fmb->{$column};
                }
            }
            # push every record in case of all open contracts
            push @records, $record unless $club_records;
        }
        # get only one record for buy sell as all other details are same
        push @records, $record if $club_records;

        foreach my $details (@records) {
            my $id = $details->{id};
            my $sell_time;
            $sell_time = Date::Utility->new($details->{sell_time})->epoch if $details->{sell_time};
            my $bid = BOM::RPC::v3::Contract::get_bid({
                short_code  => $details->{short_code},
                contract_id => $id,
                currency    => $client->currency,
                is_sold     => $details->{is_sold},
                sell_time   => $sell_time
            });
            if (exists $bid->{error}) {
                $response->{$id} = $bid;
            } else {
                $response->{$id} = {
                    transaction_ids => $details->{transaction_ids},
                    buy_price       => $details->{buy_price},
                    purchase_time   => Date::Utility->new($details->{purchase_time})->epoch,
                    account_id      => $details->{account_id},
                    is_sold         => $details->{is_sold},
                    $sell_time ? (sell_time => $sell_time) : (),
                    defined $details->{sell_price}
                    ? (sell_price => sprintf('%.2f', $details->{sell_price}))
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
