package BOM::RiskReporting::MarkedToModel;

=head1 NAME

BOM::RiskReporting::MarkedToModel

=head1 SYNOPSIS

BOM::RiskReport::MarkedToModel->new->generate;

=cut

use strict;
use warnings;

no indirect;

local $\ = undef;    # Sigh.

use Moose;
extends 'BOM::RiskReporting::Base';

use JSON::MaybeXS;
use File::Temp;
use POSIX qw(strftime);
use Try::Tiny;

use Email::Address::UseXS;
use Email::Stuffer;
use BOM::Database::ClientDB;
use BOM::Product::ContractFactory qw( produce_contract );
use Finance::Contract::Longcode qw( shortcode_to_parameters );
use Time::Duration::Concise::Localize;
use BOM::Database::DataMapper::CollectorReporting;
use BOM::Config;
use Bloomberg::UnderlyingConfig;
use Text::CSV;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::Model::Constants;
use DataDog::DogStatsd::Helper qw (stats_inc stats_timing stats_count);
use BOM::User::Client;
use BOM::Backoffice::Request;
use ExchangeRates::CurrencyConverter qw (in_usd);
use BOM::Transaction;

use constant SECONDS_PAST_CONTRACT_EXPIRY => 15;

# This report will only be run on the MLS.
sub generate {
    my $self = shift;

    my $pricing_date = $self->end;

    my $open_bets_ref = $self->live_open_bets;
    my @keys          = keys %{$open_bets_ref};

    my $open_bets_expired_ref;

    my $howmany = scalar @keys;
    my %totals  = (
        value => 0,
        delta => 0,
        theta => 0,
        vega  => 0,
        gamma => 0,
    );

    my $total_expired             = 0;
    my $error_count               = 0;
    my $last_fmb_id               = 0;
    my $waiting_for_settlement    = 0;
    my $require_manual_settlement = 0;
    my @manually_settle_fmbid     = ();
    my %cached_underlyings;
    my @mail_content;

    # Before starting pricing we'd like to make sure we'll have the ticks we need.
    # They'll all still be priced at that second, though.
    # Let's nap!
    while ($pricing_date->epoch + 5 > time) {
        sleep 1;
    }
    my $dbic = $self->_db->dbic;
    try {
        # There is side-effect in block, so I use ping mode here.
        $dbic->txn(
            ping => sub {
                my $dbh = $_;
                # This seems to be the recommended way to do transactions
                $dbh->do(qq{DELETE FROM accounting.expired_unsold});
                $dbh->do(qq{DELETE FROM accounting.realtime_book});

                foreach my $open_fmb_id (@keys) {
                    $last_fmb_id = $open_fmb_id;
                    my $open_fmb = $open_bets_ref->{$open_fmb_id};
                    try {
                        my $bet_params = shortcode_to_parameters($open_fmb->{short_code}, $open_fmb->{currency_code});

                        $bet_params->{date_pricing} = $pricing_date;
                        my $symbol = $bet_params->{underlying};
                        $bet_params->{underlying} = $cached_underlyings{$symbol}
                            if ($cached_underlyings{$symbol});
                        my $bet = produce_contract($bet_params);
                        $cached_underlyings{$symbol} ||= $bet->underlying;

                        my $current_value = $bet->is_binary ? $bet->theo_price : $bet->theo_price * $bet->multiplier;
                        my $value = $self->amount_in_usd($current_value, $open_fmb->{currency_code});
                        $totals{value} += $value;

                        if ($bet->is_expired) {
                            $total_expired++;
                            if ($bet->is_valid_to_sell) {
                                # We only sell the contracts that already expired for more than SECONDS_PAST_CONTRACT_EXPIRY seconds #
                                # Those other contracts will be sold by expiryd #
                                if (time - $bet->date_expiry->epoch > SECONDS_PAST_CONTRACT_EXPIRY) {
                                    $open_fmb->{market_price}                                           = $value;
                                    $open_fmb->{bet}                                                    = $bet;
                                    $open_bets_expired_ref->{$open_fmb->{client_loginid}}{$open_fmb_id} = $open_fmb;
                                }
                            } elsif ($bet->require_manual_settlement) {
                                $require_manual_settlement++;
                                push @manually_settle_fmbid, +{
                                    loginid   => $open_fmb->{client_loginid},
                                    ref       => $open_fmb->{transaction_id},
                                    fmb_id    => $open_fmb_id,
                                    buy_price => $open_fmb->{buy_price},
                                    currency  => $open_fmb->{currency_code},
                                    shortcode => $bet->shortcode,
                                    payout    => $bet->payout,
                                    reason    => $bet->primary_validation_error->message,
                                    # TODO: bb_lookup is a bloomberg lookup symbol that is no longer required in manual settlement page.
                                    # This will be removed in a separate card.
                                    bb_lookup => '--',
                                };
                                $dbh->do(qq{INSERT INTO accounting.expired_unsold (financial_market_bet_id, market_price) VALUES(?,?)},
                                    undef, $open_fmb_id, $value);
                            } elsif ($bet->waiting_for_settlement_tick) {
                                $waiting_for_settlement++;
                            } else {
                                push @mail_content, "Contract expired but could not be settled [$last_fmb_id,  $open_fmb->{short_code}]";
                            }
                        } else {
                            # spreaed does not have greeks
                            map { $totals{$_} += $bet->$_ } qw(delta theta vega gamma);
                            $dbh->do(
                                qq{INSERT INTO accounting.realtime_book (financial_market_bet_id, market_price, delta, theta, vega, gamma)  VALUES(?, ?, ?, ?, ?, ?)},
                                undef, $open_fmb_id, $value, $bet->delta, $bet->theta, $bet->vega, $bet->gamma
                            );
                        }
                    }
                    catch {
                        $error_count++;
                        push @mail_content, "Unable to process bet [ $last_fmb_id, " . $open_fmb->{short_code} . ", $_ ]";
                    };
                }

                $dbh->do(
                    qq{
        INSERT INTO accounting.historical_marked_to_market(calculation_time, market_value, delta, theta, vega, gamma)
        VALUES(?, ?, ?, ?, ?, ?)
        }, undef, $pricing_date->db_timestamp,
                    map { $totals{$_} } qw(value delta theta vega gamma)
                );

                if (@mail_content and $self->send_alerts) {
                    my $from    = 'Risk reporting <risk-reporting@binary.com>';
                    my $to      = 'Quants <x-quants-alert@binary.com>';
                    my $subject = 'Problem in MtM bets pricing';
                    my $body    = join "\n", @mail_content;

                    Email::Stuffer->from($from)->to($to)->subject($subject)->text_body($body)->send
                        || warn "Sending email from $from to $to subject $subject failed";
                }

            });
    }
    catch {
        my $errmsg = ref $_ ? $_->trace : $_;
        warn('Updating realtime book transaction aborted while processing bet [' . $last_fmb_id . '] because ' . $errmsg);
    };

    $self->cache_daily_turnover($pricing_date);

    $self->sell_expired_contracts($open_bets_expired_ref, \@manually_settle_fmbid);

    return {
        full_count                => $howmany,
        errors                    => $error_count,
        expired                   => $total_expired,
        waiting_for_settlement    => $waiting_for_settlement,
        require_manual_settlement => $require_manual_settlement,
    };
}

sub sell_expired_contracts {
    my $self                  = shift;
    my $open_bets_ref         = shift;
    my $manually_settle_fmbid = shift;

    # Now deal with them one by one.

    my @error_lines;
    my @client_loginids = keys %{$open_bets_ref};

    my %map_to_bb = reverse Bloomberg::UnderlyingConfig::bloomberg_to_binary();
    my $csv       = Text::CSV->new;

    for my $client_id (@client_loginids) {
        my $fmb_infos = $open_bets_ref->{$client_id};
        my $client = BOM::User::Client::get_instance({'loginid' => $client_id});
        my (@fmb_ids_to_be_sold, %bet_infos);
        for my $id (keys %$fmb_infos) {
            my $fmb_id         = $fmb_infos->{$id}->{id};
            my $expected_value = $fmb_infos->{$id}->{market_price};
            my $currency       = $fmb_infos->{$id}->{currency_code};
            my $ref_number     = $fmb_infos->{$id}->{transaction_id};
            my $buy_price      = $fmb_infos->{$id}->{buy_price};

            my $bet_info = {
                loginid   => $client_id,
                ref       => $ref_number,
                fmb_id    => $fmb_id,
                buy_price => $buy_price,
                currency  => $currency,
                bb_lookup => '--',
            };

            my $bet = $fmb_infos->{$id}{bet};

            if (my $bb_symbol = $map_to_bb{$bet->underlying->symbol}) {
                $csv->combine($map_to_bb{$bet->underlying->symbol}, $bet->date_start->db_timestamp, $bet->date_expiry->db_timestamp);
                $bet_info->{bb_lookup} = $csv->string;
            }
            $bet_info->{shortcode} = $bet->shortcode;
            $bet_info->{payout}    = $bet->payout;

            if (not defined $bet->value) {
                # $bet->value is set when we confirm expiration status, even further above.
                $bet_info->{reason} = 'indeterminate value';
                push @error_lines, $bet_info;
                next;
            }
            if (0 + $bet->bid_price xor 0 + $expected_value) {
                # We want to be sure that both sides agree that it is either worth nothing or payout.
                # Sadly, you can't compare the values directly because $expected_value has been
                # converted to USD and our payout currency might be different.
                # Since the values can come back as strings, we use the 0 + to force them to be evaluated numerically.
                $bet_info->{reason} = 'expected to be worth ' . $expected_value . ' got ' . $bet->bid_price;
                push @error_lines, $bet_info;
                next;
            }

            push @fmb_ids_to_be_sold, $fmb_id;
            $bet_infos{$fmb_id} = $bet_info;
        }

        # We may end up with no contracts to sell at this point.
        if (@fmb_ids_to_be_sold) {
            try {
                my $result = BOM::Transaction::sell_expired_contracts({
                    client       => $client,
                    contract_ids => \@fmb_ids_to_be_sold,
                    source       => 3,                      # app id for `Binary.com riskd.pl` in auth db => oauth.apps table
                });
                for my $failure (@{$result->{failures}}) {
                    my $bet_info = $bet_infos{$failure->{fmb_id}};
                    $bet_info->{reason} = $failure->{reason};
                    push @error_lines, $bet_info;
                }
            }
            catch {
                warn "Failed to sell expired contracts for "
                    . $client->loginid
                    . " - IDs were "
                    . join(',', @fmb_ids_to_be_sold)
                    . " and error was $_\n";
            }
        }
    }

    if (@$manually_settle_fmbid) {
        push @error_lines, @$manually_settle_fmbid;
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

        if (BOM::Config::on_production()) {
            my $from = '"Autosell" <autosell@regentmarkets.com>';
            my $to   = 'quants-market-data@regentmarkets.com';
            Email::Stuffer->from($from)->to($to)->subject($subject)->text_body(join("\n", @msg) . "\n\n")->send
                || warn "sending email from $from to $to subject $subject failed";
        }
    }

    return 0;
}

# cache query result for BO Daily Turnover Report
sub cache_daily_turnover {
    my $self         = shift;
    my $pricing_date = shift;

    my $curr_month    = Date::Utility->new('1-' . $pricing_date->months_ahead(0));
    my $prev_month    = Date::Utility->new('1-' . $pricing_date->months_ahead(-1));
    my $report_mapper = BOM::Database::DataMapper::CollectorReporting->new({
        broker_code => 'FOG',
        operation   => 'collector'
    });
    my $aggregate_transactions = $report_mapper->get_aggregated_sum_of_transactions_of_month({date => $curr_month->db_timestamp});

    my $eod_market_values = $report_mapper->eod_market_values_of_month($curr_month->db_timestamp);

    my $active_clients = $report_mapper->number_of_active_clients_of_month($curr_month->db_timestamp);

    my $cache_query = {
        agg_txn             => $aggregate_transactions,
        eod_open_bets_value => $eod_market_values,
        active_clients      => $active_clients,
    };

    my $cache_prefix = 'DAILY_TURNOVER';
    Cache::RedisDB->set($cache_prefix, $pricing_date->db_timestamp, JSON::MaybeXS->new->encode($cache_query), 3600 * 5);

    # when month changes
    if ($pricing_date->day_of_month == 1 and $pricing_date->hour < 3) {
        my $redis_time = Cache::RedisDB->keys($cache_prefix);    ## no critic (DeprecatedFeatures)
        my @prev_month;
        my $latest_prev;

        # get latest time of previous month
        foreach my $time (@{$redis_time}) {
            my $bom_date = Date::Utility->new($time);
            if ($bom_date->month == $prev_month->month) {
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
        }
    }
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
