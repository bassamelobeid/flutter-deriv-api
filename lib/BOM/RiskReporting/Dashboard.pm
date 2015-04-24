package BOM::RiskReporting::Dashboard;

=head1 NAME

BOM::RiskReporting::Dashboard

=head1 DESCRIPTION

Generates the report shown on our Risk Dashboard b/o page.

=cut

use strict;
use warnings;

use IO::File;
use List::Util qw(max first sum);
use JSON qw(to_json from_json);
use Moose;
use Try::Tiny;
extends 'BOM::RiskReporting::Base';

use Cache::RedisDB;
use Date::Utility;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Platform::CustomClientLimits;
use BOM::Utility::Format::Numbers qw(roundnear);
use BOM::Database::Model::Account;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Account;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::DataMapper::Transaction;
use BOM::Database::DataMapper::CollectorReporting;
use BOM::Database::AutoGenerated::Rose::MyaffiliatesTokenDetail;
use BOM::Platform::Runtime;
use Time::Duration::Concise::Localize;

=head1 ATTRIBUTES

=head2 start

The start date of the period over which the instance reports.

=head2 end

The end date of the period over which the instance reports.

=cut

has [qw( start )] => (
    is         => 'ro',
    isa        => 'Date::Utility',
    lazy_build => 1,
);

sub _build_start {
    return shift->end->minus_time_interval('1d');
}

has _limitlist => (
    is      => 'ro',
    isa     => 'BOM::Platform::CustomClientLimits',
    default => sub { return BOM::Platform::CustomClientLimits->new; },
);

has _affiliate_info => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { return {}; },
);

sub _do_name_plus {
    my ($self, $href) = @_;

    if ($href->{affiliation} and $href->{affiliate_username}) {
        $self->_affiliate_info->{$href->{affiliation}} = {
            id       => $href->{affiliation},
            username => $href->{affiliate_username},
            email    => $href->{affiliate_email},
        };
    }

    $href->{custom_limits} =
        $self->_limitlist->client_limit_list($href->{loginid});
    return $href;
}

sub _report_mapper {
    return BOM::Database::DataMapper::CollectorReporting->new({db => shift->_db});
}

has _report => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__report {
    my $self = shift;

    my $report = {
        start_date => $self->start->datetime_yyyymmdd_hhmmss,
        end_date   => $self->end->datetime_yyyymmdd_hhmmss,
    };

    $self->logger->debug('Doing open_bets.');
    $report->{open_bets} = $self->_open_bets_report;

    $self->logger->debug('Doing account_worth.');
    my $pap_report = $self->_payment_and_profit_report;
    $report->{big_deposits}    = $pap_report->{big_deposits};
    $report->{big_withdrawals} = $pap_report->{big_withdrawals};
    $report->{big_winners}     = $pap_report->{big_winners};
    $report->{big_losers}      = $pap_report->{big_losers};
    $report->{watched}         = $pap_report->{watched};

    $self->logger->debug('Doing turnover.');
    $report->{top_turnover} = $self->_top_turnover;

    return $report;
}

sub _open_bets_report {
    my $self = shift;

    my $report = {
        mover_limit => 100,
    };
    my $spark_info   = {};
    my $treemap_info = {};
    my $pivot_info   = {
        fields => {
            login_id => {
                field => 'login_id',
            },
            currency_code => {
                field => 'currency_code',
            },
            ref_no => {
                field => 'ref_no',
            },
            underlying => {
                field => 'underlying',
            },
            market => {
                field => 'market',
            },
            bet_type => {
                field => 'bet_type',
            },
            bet_category => {
                field => 'bet_category',
            },
            expiry_date => {
                field => 'expiry_date',
            },
            expiry_period => {
                field => 'expiry_period',
                sort  => 'desc'
            },
            buy_price_usd => {
                field        => 'buy_price_usd',
                sort         => 'desc',
                agregateType => 'sum',
            },
            payout_usd => {
                field        => 'payout_usd',
                sort         => 'desc',
                agregateType => 'sum',
                sort         => 'desc'
            },
            mtm_usd => {
                field        => 'mtm_usd',
                agregateType => 'sum',
                sort         => 'desc'
            },
            mtm_profit => {
                field        => 'mtm_profit',
                agregateType => 'sum',
                sort         => 'desc'
            },
            Count => {
                sort         => 'desc',
                agregateType => 'count',
                groupType    => 'none',
            },
            MtMAverage => {
                field        => 'mtm_usd',
                sort         => 'desc',
                agregateType => 'average',
                groupType    => 'none',
            },
        },
        xfields   => ['market',  'underlying'],
        yfields   => ['expiry_period'],
        zfields   => ['mtm_usd', 'mtm_profit'],
        copyright => JSON::false,
        summary   => JSON::true,
        data      => [],
    };

    my @open_bets = sort { $b->{percentage_change} <=> $a->{percentage_change} } @{$self->_open_bets_at_end};
    my @movers = grep { $self->amount_in_usd($_->{market_price}, $_->{currency_code}) >= $report->{mover_limit} } @open_bets;

# Top ten moved open positions (% change from purchase price to current MtM value)
    $report->{top_ten_movers} =
        [((scalar @movers <= 10) ? @movers : @movers[0 .. 9])];

    # big payout open positions
    @open_bets =
        sort { $self->amount_in_usd($b->{payout_price}, $b->{currency_code}) <=> $self->amount_in_usd($a->{payout_price}, $a->{currency_code}) }
        @open_bets;
    $report->{big_payouts} =
        [((scalar @open_bets <= 10) ? @open_bets : @open_bets[0 .. 9])];

    # big marked to market value
    @open_bets =
        sort { $self->amount_in_usd($b->{market_price}, $b->{currency_code}) <=> $self->amount_in_usd($a->{market_price}, $a->{currency_code}) }
        @open_bets;
    $report->{big_mtms} =
        [((scalar @open_bets <= 10) ? @open_bets : @open_bets[0 .. 9])];

    my $today      = Date::Utility->today;
    my $total_open = 0;

    foreach my $bet_details (@open_bets) {
        my $bet = produce_contract($bet_details->{short_code}, $bet_details->{currency_code});

        my $normalized_mtm = $self->amount_in_usd($bet_details->{market_price}, $bet_details->{currency_code});

        my $seconds_to_expiry = Date::Utility->new($bet_details->{expiry_time})->epoch - time;
        $total_open += $normalized_mtm;
        my $til_expiry = Time::Duration::Concise::Localize->new(
            interval => max(0, $seconds_to_expiry),
            locale   => BOM::Platform::Context::request()->language
        );
        $bet_details->{longcode} = try { $bet->longcode } catch { 'Description unavailable' };
        $bet_details->{expires_in} =
            ($til_expiry->seconds > 0) ? $til_expiry->as_string(1) : 'expired';
        my $currency      = $bet_details->{currency_code};
        my $how_long      = $bet->date_expiry->days_between($self->end);
        my $expiry_period = ($how_long < 1) ? 'Today' : 'Longer';
        my $buy_usd       = $self->amount_in_usd($bet_details->{buy_price}, $currency);
        my $payout_usd    = $self->amount_in_usd($bet_details->{payout_price}, $currency);
        my $mtm_profit    = $buy_usd - $normalized_mtm;
        my $underlying    = $bet->underlying;
        my $bet_cat       = $bet->category;
        push @{$pivot_info->{data}},
            {
            login_id      => $bet_details->{loginid},
            currency_code => $currency,
            ref_no        => $bet_details->{ref},
            underlying    => $underlying->symbol,
            market        => $underlying->market->name,
            bet_type      => $bet->code,
            bet_category  => $bet_cat->code,
            expiry_date   => $bet->date_expiry->date_yyyymmdd,
            expiry_period => $expiry_period,
            buy_price_usd => $buy_usd,
            payout_usd    => $payout_usd,
            mtm_usd       => $normalized_mtm,
            mtm_profit    => $mtm_profit,
            };
        $treemap_info->{$bet_cat->display_order}->{$underlying->display_name . ' | ' . $bet_cat->code} += $normalized_mtm;
        my $days_hence = $bet->date_expiry->days_between($today);
        $spark_info->{$days_hence}->{mtm} += $normalized_mtm;
    }

    my $sparks = {
        mtm  => [],
        days => [],
    };
    for (my $days = 0; $days <= max(keys %$spark_info, 0); $days++) {
        push @{$sparks->{mtm}}, roundnear(1, $spark_info->{$days}->{mtm} // 0);
        push @{$sparks->{days}}, $days;
    }

    # This should probably be done with B::P::Offerings,
    #  but I am just trying it.
    my $treemap = {
        data   => [],
        labels => [],
    };

    foreach my $cat (sort { $a <=> $b } keys %$treemap_info) {
        my (@ul_data, @ul_labels);
        foreach my $symbol_cat (
            sort { $treemap_info->{$cat}->{$b} <=> $treemap_info->{$cat}->{$a} }
            keys %{$treemap_info->{$cat}})
        {
            if (my $amount = roundnear(1, $treemap_info->{$cat}->{$symbol_cat})) {
                push @ul_data,   $amount;
                push @ul_labels, $symbol_cat;
            }
        }
        push @{$treemap->{data}},   \@ul_data;
        push @{$treemap->{labels}}, \@ul_labels;
    }

    $report->{pivot}   = to_json($pivot_info);
    $report->{treemap} = to_json($treemap);
    $report->{sparks}  = to_json($sparks);

    return $report;
}

sub _open_bets_at_end {
    my $self = shift;

    $self->logger->debug('Start building open bets at end');
    my $open_bets = $self->_report_mapper->get_open_bet_overviews($self->end);

    $self->logger->debug('Add extra info open bets at end');
    foreach my $bet (@{$open_bets}) {
        $self->_do_name_plus($bet);
    }
    $self->logger->debug('Done building open bets at end');

    return $open_bets;
}

sub _top_turnover {
    my $self = shift;

    my $tops = $self->_report_mapper->turnover_in_period({
        start_date => $self->start->db_timestamp,
        end_date   => $self->end->db_timestamp
    });
    my @sorted_top =
        sort { $b->{turnover} <=> $a->{turnover} }
        map { $self->_do_name_plus($tops->{$_}) } (keys %$tops);
    foreach my $entry (@sorted_top) {
        $self->_affiliate_info->{$entry->{affiliation}}->{turnover} += $entry->{turnover}
            if ($entry->{affiliation} and defined $entry->{turnover});
    }
    my @sorted_affils =
        sort { $b->{turnover} <=> $a->{turnover} }
        grep { defined $_->{turnover} }
        map  { $self->_affiliate_info->{$_} } keys %{$self->_affiliate_info};
    return +{
        clients => [(scalar @sorted_top <= 10) ? @sorted_top : @sorted_top[0 .. 9]],
        affiliates => [
            (scalar @sorted_affils <= 10)
            ? @sorted_affils
            : @sorted_affils[0 .. 9]]};
}

sub _payment_and_profit_report {
    my $self = shift;

    my @movers = $self->_report_mapper->get_active_accounts_payment_profit({
        start_time => $self->start,
        end_time   => $self->end
    });

    my @deposits = sort { $b->{usd_payments} <=> $a->{usd_payments} } @movers;
    my @withdrawals = reverse @deposits;
    my (@big_deposits, @big_withdrawals);

    for my $i (0 .. 9) {
        push @big_deposits, $deposits[$i]
            if ($deposits[$i] and $deposits[$i]->{usd_payments} > 0);
        push @big_withdrawals, $withdrawals[$i]
            if ($withdrawals[$i] and $withdrawals[$i]->{usd_payments} < 0);
    }

    my @winners = sort { $b->{usd_profit} <=> $a->{usd_profit} } @movers;
    my @losers = reverse @winners;
    my (@big_winners, @big_losers, @watched);

    for my $i (0 .. 9) {
        push @big_winners, $winners[$i]
            if ($winners[$i] and $winners[$i]->{usd_profit} > 0);
        push @big_losers, $losers[$i]
            if ($losers[$i] and $losers[$i]->{usd_profit} < 0);
    }
    my %all_watched =
        map { $_ => 1 } (keys %{$self->_limitlist->full_list});

    foreach my $mover (@movers) {
        $self->_do_name_plus($mover);
        if ($self->_limitlist->watched($mover->{loginid})) {
            push @watched, $mover;
            delete $all_watched{$mover->{loginid}};
        }
    }

    # Add in the inactive limitlist
    foreach my $espied (
        map { +{loginid => $_, currency => 'ALL'} }
        keys %all_watched
        )
    {
        $self->_do_name_plus($espied);
        push @watched, $espied;
    }

    @watched =
        sort { $a->{loginid} cmp $b->{loginid} }
        sort { $a->{currency} cmp $b->{currency} } @watched;

    return {
        big_deposits    => \@big_deposits,
        big_withdrawals => \@big_withdrawals,
        big_winners     => \@big_winners,
        big_losers      => \@big_losers,
        watched         => \@watched,
    };
}

=head1 METHODS

=head2 generate

Generates the report, ignoring any caching. Returns the report, which is a HashRef.

=cut

sub generate {
    my $self = shift;

    $self->logger->debug('Starting to generate.');

    _write_cache($self->_report, 7200);    # Good for 2 hours.

    $self->logger->debug('Finished generating.');

    return $self->_report;
}

sub _read_cache { return Cache::RedisDB->get('RISK_DASHBOARD', 'report') }

sub _write_cache {
    my ($values, $ttl) = @_;
    Cache::RedisDB->set('RISK_DASHBOARD', 'report', $values, $ttl);
    return;
}

=head2 fetch

Same behavior as generate, but will take the report from cache if present.

=cut

sub fetch {
    my $self = shift;

    return (_read_cache || $self->generate);
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
