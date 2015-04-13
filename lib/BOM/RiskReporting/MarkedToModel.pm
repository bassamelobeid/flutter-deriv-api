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

# This report will only be run on the MLS.
sub generate {
    my $self = shift;

    my $start = time;

    my $pricing_date = $self->end;

    $self->logger->debug('Finding open positions.');
    my $open_bets_ref = $self->live_open_bets;
    my @keys          = keys %{$open_bets_ref};

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

                my $value = $self->amount_in_usd($bet->theo_price, $open_fmb->{currency_code});
                $totals{value} += $value;

                if ($bet->is_expired) {
                    $self->logger->debug(
                        'expired_unsold: ' . join('::', $open_fmb_id, $value, $bet->shortcode, $bet->is_expired, $bet->initialized_correctly));
                    $total_expired++;
                    $dbh->do(qq{INSERT INTO accounting.expired_unsold (financial_market_bet_id, market_price) VALUES(?,?)},
                        undef, $open_fmb_id, $value);
                } else {
                    map { $totals{$_} += $bet->$_ } qw(delta theta vega gamma);
                    $dbh->do(
                        qq{INSERT INTO accounting.realtime_book (financial_market_bet_id, market_price, delta, theta, vega, gamma)  VALUES(?, ?, ?, ?, ?, ?)},
                        undef, $open_fmb_id, $value, $bet->delta, $bet->theta, $bet->vega, $bet->gamma
                    );
                }
            }
            catch {
                $error_count++;
                $mail_content .=
                    "Unable to process bet [ $last_fmb_id, " . $open_fmb->{short_code} . " ] because  [" . (ref $_ ? $_->trace : $_) . "]\n";
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

    $self->cache_daily_turnover($pricing_date);

    return {
        full_count => $howmany,
        errors     => $error_count,
        expired    => $total_expired
    };
}

# cache query result for BO Daily Turnover Report
sub cache_daily_turnover {
    my $self         = shift;
    my $pricing_date = shift;

    $self->logger->info('query daily turnover to cache in redis');

    my $curr_month    = BOM::Utility::Date->new('1-' . BOM::Utility::Date->today->months_ahead(0));
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
            my $bom_date = BOM::Utility::Date->new($time);
            if ($bom_date->month == ($curr_month->month - 1)) {
                push @prev_month, $bom_date;

                if (not $latest_prev or $bom_date->epoch > $latest_prev->epoch) {
                    $latest_prev = $bom_date;
                }
            }
        }

        # keep previous month latest cache for 60 days
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
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
