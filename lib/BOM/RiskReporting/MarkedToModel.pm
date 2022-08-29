package BOM::RiskReporting::MarkedToModel;

=head1 NAME

BOM::RiskReporting::MarkedToModel

=head1 SYNOPSIS

BOM::RiskReporting::MarkedToModel->new->generate;

=cut

use strict;
use warnings;

no indirect;

use Moose;
extends 'BOM::RiskReporting::Base';

use JSON::MaybeXS;
use Syntax::Keyword::Try;

use Brands;
use Email::Address::UseXS;
use Email::Stuffer;
use BOM::Database::ClientDB;
use BOM::Product::ContractFactory qw( produce_contract );
use Finance::Contract::Longcode   qw( shortcode_to_parameters );
use BOM::Database::DataMapper::CollectorReporting;
use BOM::Config;
use DataDog::DogStatsd::Helper qw( stats_gauge );
use BOM::Transaction;
use BOM::Transaction::Utility;
use List::Util qw(max);
use Log::Any   qw($log);

use constant SECONDS_PAST_CONTRACT_EXPIRY => 15;

# This report will only be run on the MLS.
sub generate {
    my $self         = shift;
    my $pricing_date = $self->end;
    my $client_dbs   = $self->all_client_dbs;
    die 'No client db is available' if scalar @$client_dbs == 0;

    my %open_bets = ();
    for my $client_db (@$client_dbs) {
        $log->tracef('Getting contracts on %s', $client_db->{database});
        my $db_open_bets = $self->open_bets_of($client_db);
        @open_bets{keys %$db_open_bets} = values %$db_open_bets;
    }

    my $settlement_result = $self->check_open_bets(\%open_bets, $pricing_date);

    $log->debugf('Settlement result: %s', $settlement_result);
    return $settlement_result;
}

sub check_open_bets {
    my ($self, $open_bets_ref, $pricing_date) = @_;
    my @keys                  = keys %$open_bets_ref;
    my $open_bets_expired_ref = {};

    my $howmany = scalar @keys;
    my %totals  = (
        value => 0,
        delta => 0,
        theta => 0,
        vega  => 0,
        gamma => 0,
    );

    my $total_expired          = 0;
    my $error_count            = 0;
    my $last_fmb_id            = 0;
    my $waiting_for_settlement = 0;
    my @manually_settle_fmbid  = ();
    my @mail_content;
    my $make_contract = contract_maker($pricing_date);

    # Before starting pricing we'd like to make sure we'll have the ticks we need.
    # They'll all still be priced at that second, though.
    # Let's nap!
    sleep max(5 - (time - $pricing_date->epoch), 0);

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
                        my $bet = $make_contract->($open_fmb);

                        # $current_value is the value of the open contract if it is sold back to us. So, this should be bid price for all contract.
                        my $current_value = $bet->bid_price;
                        my $value         = $self->amount_in_usd($current_value, $open_fmb->{currency_code});
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
                                push @manually_settle_fmbid, get_fmb_for_manual_settlement($open_fmb, $bet, $bet->primary_validation_error->message);
                                $dbh->do(qq{INSERT INTO accounting.expired_unsold (financial_market_bet_id, market_price) VALUES(?,?)},
                                    undef, $open_fmb_id, $value);
                            } elsif ($bet->waiting_for_settlement_tick) {
                                # If settlement tick does not update after a day, that is something wrong. Manual settlement is needed.
                                if ((Date::Utility->new->epoch - $bet->date_expiry->epoch) < 60 * 60 * 24) {
                                    $waiting_for_settlement++;
                                } else {
                                    push @manually_settle_fmbid,
                                        get_fmb_for_manual_settlement($open_fmb, $bet, 'Settlement tick is missing. Please check.');
                                    $dbh->do(qq{INSERT INTO accounting.expired_unsold (financial_market_bet_id, market_price) VALUES(?,?)},
                                        undef, $open_fmb_id, $value);
                                }
                            } else {
                                push @mail_content, "Contract expired but could not be settled [$last_fmb_id,  $open_fmb->{short_code}]";
                            }
                        } else {
                            my @greeks;
                            foreach my $greek (qw(delta theta vega gamma)) {
                                # callputspread and multiplier does not have greeks
                                my $value = ($bet->category_code eq 'multiplier' or $bet->category_code eq 'callputspread') ? 0 : $bet->$greek;
                                $totals{$greek} += $value;
                                push @greeks, $value;
                            }
                            $dbh->do(
                                qq{INSERT INTO accounting.realtime_book (financial_market_bet_id, market_price, delta, theta, vega, gamma)  VALUES(?, ?, ?, ?, ?, ?)},
                                undef, $open_fmb_id, $value, @greeks
                            );
                        }
                    } catch ($e) {
                        $error_count++;
                        push @mail_content, "Unable to process bet [ $last_fmb_id, " . $open_fmb->{short_code} . ", $e ]";
                    }
                }

                $dbh->do(
                    qq{INSERT INTO accounting.historical_marked_to_market(calculation_time, market_value, delta, theta, vega, gamma) VALUES(?, ?, ?, ?, ?, ?) },
                    undef, $pricing_date->db_timestamp, map { $totals{$_} } qw(value delta theta vega gamma)
                );

                if (@mail_content and $self->send_alerts) {
                    my $from    = 'Risk reporting <risk-reporting@binary.com>';
                    my $to      = Brands->new(name => 'deriv')->emails('quants');
                    my $subject = 'Problem in MtM bets pricing';
                    my $body    = join "\n", @mail_content;

                    Email::Stuffer->from($from)->to($to)->subject($subject)->text_body($body)->send
                        || $log->warn("Sending email from $from to $to subject $subject failed");
                }

            });
    } catch ($e) {
        my $errmsg = ref $e ? $e->trace : $e;
        $log->warn('Updating realtime book transaction aborted while processing bet [' . $last_fmb_id . '] because ' . $errmsg);
    }

    DataDog::DogStatsd::Helper::stats_gauge('bom_backoffice.riskd.expired_unsold_contracts', scalar @manually_settle_fmbid);
    $self->_cache_expired_contracts($open_bets_expired_ref, \@manually_settle_fmbid);
    $self->cache_daily_turnover($pricing_date);

    return {
        full_count                => $howmany,
        errors                    => $error_count,
        expired                   => $total_expired,
        waiting_for_settlement    => $waiting_for_settlement,
        require_manual_settlement => scalar @manually_settle_fmbid,
    };
}

sub _cache_expired_contracts {
    my $self                  = shift;
    my $open_bets_ref         = shift;
    my $manually_settle_fmbid = shift;

    my @error_lines;

    my @client_loginids = keys %{$open_bets_ref};

    for my $client_id (@client_loginids) {
        my $fmb_infos = $open_bets_ref->{$client_id};
        my %bet_infos;
        for my $id (keys %$fmb_infos) {
            my $fmb_id         = $fmb_infos->{$id}{id};
            my $expected_value = $fmb_infos->{$id}{market_price};
            my $currency       = $fmb_infos->{$id}{currency_code};
            my $ref_number     = $fmb_infos->{$id}{transaction_id};
            my $buy_price      = $fmb_infos->{$id}{buy_price};
            my $bet            = $fmb_infos->{$id}{bet};

            my $bet_info = {
                loginid   => $client_id,
                ref       => $ref_number,
                fmb_id    => $fmb_id,
                buy_price => $buy_price,
                currency  => $currency,
                shortcode => $bet->shortcode,
                payout    => $bet->payout,
            };

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

            $bet_infos{$fmb_id} = $bet_info;
        }
    }

    if (@$manually_settle_fmbid) {
        push @error_lines, @$manually_settle_fmbid;
    }

    if (scalar @error_lines) {
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
            my $to   = Brands->new(name => 'deriv')->emails('quants');
            Email::Stuffer->from($from)->to($to)->subject($subject)->text_body(join("\n", @msg) . "\n\n")->send
                || $log->warn("sending email from $from to $to subject $subject failed");
        }
    }
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

sub contract_maker {
    my $pricing_date       = shift;
    my %cached_underlyings = ();

    return sub {
        my $open_fmb   = shift;
        my $bet_params = shortcode_to_parameters($open_fmb->{short_code}, $open_fmb->{currency_code});
        $bet_params->{date_pricing} = $pricing_date;
        $bet_params->{limit_order}  = BOM::Transaction::Utility::extract_limit_orders($open_fmb);

        my $symbol = $bet_params->{underlying};
        $bet_params->{underlying} = $cached_underlyings{$symbol} if $cached_underlyings{$symbol};

        my $bet = produce_contract($bet_params);
        $cached_underlyings{$symbol} ||= $bet->underlying;
        return $bet;
    }
}

sub get_fmb_for_manual_settlement {
    my ($open_fmb, $bet, $error) = @_;
    return {
        loginid   => $open_fmb->{client_loginid},
        ref       => $open_fmb->{transaction_id},
        fmb_id    => $open_fmb->{id},
        buy_price => $open_fmb->{buy_price},
        currency  => $open_fmb->{currency_code},
        shortcode => $open_fmb->{short_code},
        payout    => $bet->payout,
        reason    => $error,
    };
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
