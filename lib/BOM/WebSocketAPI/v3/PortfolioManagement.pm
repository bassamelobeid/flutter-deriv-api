package BOM::WebSocketAPI::v3::PortfolioManagement;

use strict;
use warnings;

use Mojo::DOM;
use Date::Utility;
use Try::Tiny;

use BOM::WebSocketAPI::v3::Utility;
use BOM::WebSocketAPI::v3::MarketDiscovery;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw (localize);
use BOM::Product::ContractFactory qw(produce_contract make_similar_contract);
use BOM::Product::Transaction;

sub portfolio {
    my $client = shift;

    my $portfolio = {contracts => []};
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
            longcode =>
                Mojo::DOM->new->parse(BOM::Product::ContractFactory::produce_contract($row->{short_code}, $client->currency)->longcode)->all_text
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

sub get_bid {
    my ($short_code, $contract_id, $currency) = @_;

    my $contract = produce_contract($short_code, $currency);

    my %returnhash = (
        ask_price           => sprintf('%.2f', $contract->ask_price),
        bid_price           => sprintf('%.2f', $contract->bid_price),
        current_spot_time   => $contract->current_tick->epoch,
        contract_id         => $contract_id,
        underlying          => $contract->underlying->symbol,
        is_expired          => $contract->is_expired,
        is_valid_to_sell    => $contract->is_valid_to_sell,
        is_forward_starting => $contract->is_forward_starting,
        is_path_dependent   => $contract->is_path_dependent,
        is_intraday         => $contract->is_intraday,
        date_start          => $contract->date_start->epoch,
        date_expiry         => $contract->date_expiry->epoch,
        date_settlement     => $contract->date_settlement->epoch,
        currency            => $contract->currency,
        longcode            => $contract->longcode,
        shortcode           => $contract->shortcode,
        payout              => $contract->payout,
    );

    if ($contract->expiry_type eq 'tick') {
        $returnhash{prediction}      = $contract->prediction;
        $returnhash{tick_count}      = $contract->tick_count;
        $returnhash{entry_tick}      = $contract->entry_tick->quote;
        $returnhash{entry_tick_time} = $contract->entry_tick->epoch;
        $returnhash{exit_tick}       = $contract->exit_tick->quote;
        $returnhash{exit_tick_time}  = $contract->exit_tick->epoch;
    } else {
        $returnhash{current_spot} = $contract->current_spot;
        $returnhash{entry_spot}   = $contract->entry_spot;
    }

    if ($contract->two_barriers) {
        $returnhash{high_barrier} = $contract->high_barrier->as_absolute;
        $returnhash{low_barrier}  = $contract->low_barrier->as_absolute;
    } elsif ($contract->barrier) {
        $returnhash{barrier} = $contract->barrier->as_absolute;
    }

    if ($contract->expiry_type ne 'tick' and not $contract->is_valid_to_sell) {
        $returnhash{validation_error} = $contract->primary_validation_error->message_to_client;
    }

    return \%returnhash;
}

1;
