package BOM::RiskReporting::MarkedToModel;

=head1 NAME

BOM::RiskReporting::MarkedToModel

=head1 SYNOPSIS

BOM::RiskReport::MarkedToModel->new->generate;

=cut

use strict;
use warnings;

local $\ = undef;    # Sigh.

use Moose;
extends 'BOM::RiskReporting::Base';

use JSON qw(to_json);
use File::Temp;
use POSIX qw(strftime);
use Try::Tiny;

use Mail::Sender;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::HistoricalMarkedToMarket;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Product::ContractFactory::Parser qw( shortcode_to_parameters );
use Time::Duration::Concise::Localize;
use BOM::Database::DataMapper::CollectorReporting;
use BOM::System::Config;
use Bloomberg::UnderlyingConfig;
use Text::CSV;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::Model::Constants;
use DataDog::DogStatsd::Helper qw (stats_inc stats_timing stats_count);
use BOM::Platform::Client;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Utility::CurrencyConverter qw (in_USD);

# This report will only be run on the MLS.
sub generate {
    my $self = shift;

    my $start = time;

    my $pricing_date = $self->end;

    $self->logger->debug('Finding open positions.');
    my $open_bets_ref = $self->live_open_bets;
    my @keys          = keys %{$open_bets_ref};

    my $open_bets_expired_ref;

    my $howmany = scalar @keys;
    my $expired = 0;
    my %totals  = (
        value => 0,
        delta => 0,
        theta => 0,
        vega  => 0,
        gamma => 0,
    );
    $self->logger->debug('Found ' . $howmany . ' open positions.');

    my $total_expired = 0;
    my $error_count   = 0;
    my $last_fmb_id   = 0;
    my %cached_underlyings;
    my $mail_content = '';

    # Before starting pricing we'd like to make sure we'll have the ticks we need.
    # They'll all still be priced at that second, though.
    # Let's nap!
    while ($pricing_date->epoch + 5 > time) {
        sleep 1;
    }
    my $dbh = $self->_db->dbh;
    try {
        # This seems to be the recommended way to do transactions
        $dbh->{AutoCommit} = 0;
        $dbh->{RaiseError} = 1;

        my $book    = [];
        my $expired = [];

        $dbh->do(qq{DELETE FROM accounting.expired_unsold});
        $dbh->do(qq{DELETE FROM accounting.realtime_book});
        $self->logger->debug('Starting pricing for ' . $howmany . ' open positions.');

        foreach my $open_fmb_id (@keys) {

            $last_fmb_id = $open_fmb_id;
            my $open_fmb = $open_bets_ref->{$open_fmb_id};
            try {
                my $bet_params = shortcode_to_parameters($open_fmb->{short_code}, $open_fmb->{currency_code});
                $bet_params->{date_pricing} = $pricing_date;
                my $symbol = $bet_params->{underlying}->symbol;
                $bet_params->{underlying} = $cached_underlyings{$symbol}
                    if ($cached_underlyings{$symbol});
                my $bet = produce_contract($bet_params);

                $cached_underlyings{$symbol} ||= $bet->underlying;

                die 'Missing spot.' if (not $bet->underlying->spot);

                my $current_value = $bet->is_spread ? $bet->bid_price : $bet->theo_price;
                my $value = $self->amount_in_usd($current_value, $open_fmb->{currency_code});
                $totals{value} += $value;

                if ($bet->is_expired) {
                    $self->logger->debug(
                        'expired_unsold: ' . join('::', $open_fmb_id, $value, $bet->shortcode, $bet->is_expired, $bet->primary_validation_error));
                    $total_expired++;
                    $dbh->do(qq{INSERT INTO accounting.expired_unsold (financial_market_bet_id, market_price) VALUES(?,?)},
                        undef, $open_fmb_id, $value);
                    $open_bets_expired_ref->{$open_fmb_id} = $open_fmb;
                    $open_bets_expired_ref->{$open_fmb_id}->{market_price} = $value;
                } else {
                    # spreaed does not have greeks
                    if ($bet->is_spread) {
                        $dbh->do(qq{INSERT INTO accounting.realtime_book (financial_market_bet_id, market_price)  VALUES(?, ?)},
                            undef, $open_fmb_id, $value);
                    } else {
                        map { $totals{$_} += $bet->$_ } qw(delta theta vega gamma);
                        $dbh->do(
                            qq{INSERT INTO accounting.realtime_book (financial_market_bet_id, market_price, delta, theta, vega, gamma)  VALUES(?, ?, ?, ?, ?, ?)},
                            undef, $open_fmb_id, $value, $bet->delta, $bet->theta, $bet->vega, $bet->gamma
                        );
                    }
                }
            }
            catch {
                $error_count++;
                $mail_content .= "Unable to process bet [ $last_fmb_id, " . $open_fmb->{short_code} . ", $_ ]\n";
            };
        }

        my $howlong = Time::Duration::Concise::Localize->new(
            interval => time - $start,
            locale   => BOM::Platform::Context::request()->language
        );

        my $status =
              'Total time ['
            . $howlong->as_string
            . '] for ['
            . $howmany
            . '] positions (['
            . $total_expired
            . '] expired, ['
            . $error_count
            . '] errors).';

        $self->logger->info('Realtime book data calculated. '
                . $status
                . ' Historical MtM data = ['
                . join(', ', map { "$_: " . $totals{$_} } qw(value delta theta vega gamma))
                . ']');

        $dbh->do(
            qq{
        INSERT INTO accounting.historical_marked_to_market(calculation_time, market_value, delta, theta, vega, gamma)
        VALUES(?, ?, ?, ?, ?, ?)
        }, undef, $pricing_date->db_timestamp,
            map { $totals{$_} } qw(value delta theta vega gamma)
        );

        $dbh->commit;
        $self->logger->debug('Realtime book updated. ' . $status);
        if ($mail_content and $self->send_alerts) {
            $self->logger->info('Realtime book was not able to process all bets. An email was sent to quants');
            my $sender = Mail::Sender->new({
                smtp    => 'localhost',
                from    => 'Risk reporting <risk-reporting@binary.com>',
                to      => 'Quants <x-quants-alert@binary.com>',
                subject => 'Problem in MtM bets pricing',
            });
            $sender->MailMsg({msg => $mail_content});
        }

        $dbh->disconnect;
        $self->logger->debug('Finished.');
    }
    catch {
        my $errmsg = ref $_ ? $_->trace : $_;
        $self->logger->warn('Updating realtime book transaction aborted while processing bet [' . $last_fmb_id . '] because ' . $errmsg);
        try { $dbh->rollback };
    };

    $self->logger->debug('Cache Daily Turnover.');
    $self->cache_daily_turnover($pricing_date);

    $self->logger->debug('Sell Expired Contracts.');
    $self->sell_expired_contracts($open_bets_expired_ref);

    return {
        full_count => $howmany,
        errors     => $error_count,
        expired    => $total_expired
    };
}

sub sell_expired_contracts {
    my $self          = shift;
    my $open_bets_ref = shift;

    # Now deal with them one by one.

    my @error_lines;
    my @full_list = keys %{$open_bets_ref};
    my %map_to_bb = reverse Bloomberg::UnderlyingConfig::bloomberg_to_binary();
    my $csv       = Text::CSV->new;

    my $rmgenv = BOM::System::Config::env;
    while (scalar @error_lines < 100 and my $id = shift @full_list) {
        my $fmb_id         = $open_bets_ref->{$id}->{id};
        my $client_id      = $open_bets_ref->{$id}->{client_loginid};
        my $expected_value = $open_bets_ref->{$id}->{market_price};
        my $currency       = $open_bets_ref->{$id}->{currency_code};
        my $ref_number     = $open_bets_ref->{$id}->{transaction_id};
        my $buy_price      = $open_bets_ref->{$id}->{buy_price};

        my $bet_info = {
            loginid   => $client_id,
            ref       => $ref_number,
            fmb_id    => $fmb_id,
            buy_price => $buy_price,
            currency  => $currency,
            bb_lookup => '--',
        };

        my $client = BOM::Platform::Client::get_instance({'loginid' => $client_id});

        my $fmb = BOM::Database::DataMapper::FinancialMarketBet->new({broker_code => $client->broker})->get_fmb_by_id([$fmb_id])->[0];

        my $bet = try { produce_contract($fmb, $currency) };
        if (not $bet) {
            # Not a `catch` block, because we need to be able to 'next' the loop
            $bet_info->{shortcode} = $fmb->short_code;
            $bet_info->{payout}    = 'unknown';
            $bet_info->{reason}    = 'Could not instantiate contract object';
            push @error_lines, $bet_info;
            next;    # Nothing else to do.
        }

        # Database sync could be delayed resulting in riskd trying resell them again.
        # Skip them here.
        next if $bet->is_sold;

        my $stats_data = do {
            my $bet_class = $BOM::Database::Model::Constants::BET_TYPE_TO_CLASS_MAP->{$bet->code};
            my $broker    = lc($client->broker_code);
            my $virtual   = $client->is_virtual ? 'yes' : 'no';
            my $tags      = {
                tags => [
                    "broker:$broker",     "virtual:$virtual", "rmgenv:$rmgenv", "contract_class:$bet_class",
                    "sell_type:autosell", "client:" . lc($client_id),
                ]};
            stats_inc("transaction.sell.attempt", $tags);
            +{
                tags    => $tags,
                virtual => $virtual,
            };
        };

        if (my $bb_symbol = $map_to_bb{$bet->underlying->symbol}) {
            $csv->combine($map_to_bb{$bet->underlying->symbol}, $bet->date_start->db_timestamp, $bet->date_expiry->db_timestamp);
            $bet_info->{bb_lookup} = $csv->string;
        }
        $bet_info->{shortcode} = $bet->shortcode;
        # for spread max payout is determined by stop_profit.
        $bet_info->{payout} = $bet->is_spread ? $bet->amount_per_point * $bet->stop_profit : $bet->payout;

        # We do this here because part of being "initialized_correctly" below
        # is hidden behind lazy attributes.  Makes you question the name of the method.
        # Regardless, expiry check will exercise them and we need that info in a couple line anyway.
        my $expired = $bet->is_expired;

        if ($bet->primary_validation_error) {
            $bet_info->{reason} = $bet->primary_validation_error->message;
        } elsif (not $expired) {
            $bet_info->{reason} = 'not expired';
        } elsif (not defined $bet->value) {
            # $bet->value is set when we confirm expiration status, even further above.
            $bet_info->{reason} = 'indeterminate value';
        } elsif (0 + $bet->bid_price xor 0 + $expected_value) {
            # We want to be sure that both sides agree that it is either worth nothing or payout.
            # Sadly, you can't compare the values directly because $expected_value has been
            # converted to USD and our payout currency might be different.
            # Since the values can come back as strings, we use the 0 + to force them to be evaluated numerically.
            $bet_info->{reason} = 'expected to be worth ' . $expected_value . ' got ' . $bet->bid_price;
        } else {
            try {
                if ($bet->is_valid_to_sell) {
                    BOM::Database::Helper::FinancialMarketBet->new({
                            transaction_data => {
                                staff_loginid => 'AUTOSELL',
                            },
                            bet_data => {
                                id         => $fmb_id,
                                sell_price => $bet->bid_price,
                                sell_time  => $bet->date_pricing->db_timestamp,
                            },
                            account_data => {
                                client_loginid => $client_id,
                                currency_code  => $currency
                            },
                            db => BOM::Database::ClientDB->new({
                                    client_loginid => $client_id,
                                }
                            )->db,
                        })->sell_bet;

                    stats_inc("transaction.sell.success", $stats_data->{tags});
                    if ($rmgenv eq 'production' and $stats_data->{virtual} eq 'no') {
                        my $usd_amount = int(in_USD($bet->bid_price, $currency) * 100);
                        stats_count('business.buy_minus_sell_usd', -$usd_amount, $stats_data->{tags});
                    }
                } else {
                    if ($bet->can('corporate_actions') and @{$bet->corporate_actions}) {

                        $bet_info->{reason} =
                            "This contract is affected by corporate action. Can you please verify the contract has been adjusted correctly to the corporte action.";
                    } else {

                        $bet_info->{reason} = $bet->primary_validation_error->message;
                    }
                }
            }
            catch {
                $bet_info->{reason} = $_;
            };
        }
        push @error_lines, $bet_info if (exists $bet_info->{reason});
    }

    if (scalar @error_lines) {
        local ($/, $\) = ("\n", undef);    # in case overridden elsewhere
        Cache::RedisDB->set('AUTOSELL', 'ERRORS', \@error_lines, 3600);
        my $sep     = '---';
        my $subject = 'AutoSell Failures during riskd operation';
        # I dislike building URLs this way, but I don't seem to have much choice.
        my @msg = ($subject, '', 'Review and settle at https://collector01.binary.com/d/backoffice/quant/settle_contracts.cgi', '', $sep);

        foreach my $failure (@error_lines) {
            # We could have done this above, but whatever.
            push @msg,
                (
                'Shortcode:   ' . $failure->{shortcode},
                'Ref No.:     ' . $failure->{ref},
                'Client:      ' . $failure->{loginid},
                'Reason:      ' . $failure->{reason},
                'Buy Price:   ' . $failure->{currency} . ' ' . $failure->{buy_price},
                'Full Payout: ' . $failure->{currency} . ' ' . $failure->{payout},
                $sep
                );
        }

        if (BOM::Platform::Runtime->instance->app_config->system->on_production) {
            my $sender = Mail::Sender->new({
                smtp    => 'localhost',
                from    => '"Autosell" <autosell@regentmarkets.com>',
                to      => 'quants-market-data@regentmarkets.com',
                subject => $subject,
            });
            $sender->MailMsg({msg => join("\n", @msg) . "\n\n"});
        }
    }

    return 0;
}

# cache query result for BO Daily Turnover Report
sub cache_daily_turnover {
    my $self         = shift;
    my $pricing_date = shift;

    $self->logger->info('query daily turnover to cache in redis');

    my $curr_month    = Date::Utility->new('1-' . $pricing_date->months_ahead(0));
    my $report_mapper = BOM::Database::DataMapper::CollectorReporting->new({
        broker_code => 'FOG',
        operation   => 'collector'
    });
    my $aggregate_transactions = $report_mapper->get_aggregated_sum_of_transactions_of_month({date => $curr_month->db_timestamp});

    my $eod_market_values = BOM::Database::DataMapper::HistoricalMarkedToMarket->new({
            broker_code => 'FOG',
            operation   => 'collector'
        })->eod_market_values_of_month($curr_month->db_timestamp);

    my $active_clients = $report_mapper->number_of_active_clients_of_month($curr_month->db_timestamp);

    my $cache_query = {
        agg_txn             => $aggregate_transactions,
        eod_open_bets_value => $eod_market_values,
        active_clients      => $active_clients,
    };

    my $cache_prefix = 'DAILY_TURNOVER';
    Cache::RedisDB->set($cache_prefix, $pricing_date->db_timestamp, to_json($cache_query), 3600 * 5);

    $self->logger->info('DONE caching query in redis');

    # when month changes
    if ($pricing_date->day_of_month == 1 and $pricing_date->hour < 3) {
        my $redis_time = Cache::RedisDB->keys($cache_prefix);
        my @prev_month;
        my $latest_prev;

        # get latest time of previous month
        foreach my $time (@{$redis_time}) {
            my $bom_date = Date::Utility->new($time);
            if ($bom_date->month == ($curr_month->month - 1)) {
                push @prev_month, $bom_date;

                if (not $latest_prev or $bom_date->epoch > $latest_prev->epoch) {
                    $latest_prev = $bom_date;
                }
            }
        }

        # keep previous month latest cache for 60 days
        if ($latest_prev) {
            my $cache_query = Cache::RedisDB->get($cache_prefix, $latest_prev->db_timestamp);
            Cache::RedisDB->set($cache_prefix, $latest_prev->db_timestamp, $cache_query, 86400 * 60);

            # delete all other cache for previous month
            foreach my $time (@prev_month) {
                if ($time->db_timestamp ne $latest_prev->db_timestamp) {
                    Cache::RedisDB->del($cache_prefix, $time->db_timestamp);
                }
            }
            $self->logger->info('Keep long cache for prev month: ' . $latest_prev->db_timestamp);
        }
    }
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
