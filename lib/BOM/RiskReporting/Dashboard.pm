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
use JSON::MaybeXS;
use Moose;
use Try::Tiny;
use Cache::RedisDB;
use Date::Utility;
use Format::Util::Numbers qw(roundcommon financialrounding);
use Time::Duration::Concise::Localize;
extends 'BOM::RiskReporting::Base';
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Database::Model::Account;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Account;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::DataMapper::Transaction;
use BOM::Database::DataMapper::CollectorReporting;
use BOM::Database::AutoGenerated::Rose::MyaffiliatesTokenDetail;
use BOM::Platform::Runtime;
use BOM::Backoffice::Request;
use List::MoreUtils qw(uniq);
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Product::Contract::PredefinedParameters;
use Postgres::FeedDB::CurrencyConverter qw(in_USD);
my $json = JSON::MaybeXS->new;

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

has custom_client_profiles => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build_custom_client_profiles {
    return $json->decode(BOM::Platform::Runtime->instance->app_config->quants->custom_client_profiles);
}

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

    my $app_config = $self->custom_client_profiles;
    my $reason = $app_config->{$href->{loginid}}->{reason} // '';
    $href->{being_watched_for} = $reason;
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
    my $ttl = Cache::RedisDB->ttl('RISK_DASHBOARD', 'report');
    $report->{open_bets} = $self->_open_bets_report;
    my $pap_report = $self->_payment_and_profit_report;
    $report->{big_deposits}    = $pap_report->{big_deposits};
    $report->{big_withdrawals} = $pap_report->{big_withdrawals};
    $report->{big_winners}     = $pap_report->{big_winners};
    $report->{big_losers}      = $pap_report->{big_losers};
    $report->{watched}         = $pap_report->{watched};
    $report->{top_turnover}    = $self->_top_turnover;
    $report->{generated_time}  = Date::Utility->new->plus_time_interval(($ttl - 1800).'s')->datetime;
    return $report;
}

sub _open_bets_report {
    my $self = shift;

    my $report = {
        mover_limit => 100,
    };
    my $spark_info = {};
    my $pivot_info = {
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
        copyright => $json->false,
        summary   => $json->true,
        data      => [],
    };

    my @open_bets = sort { $b->{percentage_change} <=> $a->{percentage_change} } @{$self->_open_bets_at_end};
    my @movers = grep { $self->amount_in_usd($_->{market_price}, $_->{currency_code}) >= $report->{mover_limit} } @open_bets;

# Top ten moved open positions (% change from purchase price to current MtM value)
    $report->{top_ten_movers} =
        [((scalar @movers <= 10) ? @movers : @movers[0 .. 9])];

    # big marked to market value
    @open_bets =
        map  { $_->[1] }
        sort { $b->[0] <=> $a->[0] }
        map  { [$self->amount_in_usd($_->{market_price}, $_->{currency_code}), $_] } @open_bets;
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
            locale   => BOM::Backoffice::Request::request()->language
        );
        $bet_details->{longcode} = try { BOM::Backoffice::Request::localize($bet->longcode) } catch { 'Description unavailable' };
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
        my $days_hence = $bet->date_expiry->days_between($today);
        $spark_info->{$days_hence}->{mtm} += $normalized_mtm;
    }

    # big payout open positions
    my @big_payouts =
        map  { $_->[1] }
        sort { $b->[0] <=> $a->[0] }
        map  { [$self->amount_in_usd($_->{payout_price}, $_->{currency_code}), $_] } @open_bets;
    $report->{big_payouts} =
        [((scalar @big_payouts <= 10) ? @big_payouts : @big_payouts[0 .. 9])];

    my $sparks = {
        mtm  => [],
        days => [],
    };
    for (my $days = 0; $days <= max(keys %$spark_info, 0); $days++) {
        push @{$sparks->{mtm}}, roundcommon(1, $spark_info->{$days}->{mtm} // 0);
        push @{$sparks->{days}}, $days;
    }

    $report->{pivot}  = $json->encode($pivot_info);
    $report->{sparks} = $json->encode($sparks);

    return $report;
}

sub _open_bets_at_end {
    my $self = shift;

    my $open_bets = $self->_report_mapper->get_open_bet_overviews($self->end);

    foreach my $bet (@{$open_bets}) {
        $self->_do_name_plus($bet);
    }

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
        map { $_ => 1 } (keys %{$self->custom_client_profiles});

    foreach my $mover (@movers) {
        $self->_do_name_plus($mover);
        if ($all_watched{$mover->{loginid}}) {
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
        sort { $a->{currency} cmp $b->{currency} } grep { $_->{being_watched_for} } @watched;

    return {
        big_deposits    => \@big_deposits,
        big_withdrawals => \@big_withdrawals,
        big_winners     => \@big_winners,
        big_losers      => \@big_losers,
        watched         => \@watched,
    };
}

sub multibarrierreport {
    my $self      = shift;
    my @open_bets = @{$self->_open_bets_at_end};
    my $multibarrier;
    my $symbol;
    foreach my $open_contract (@open_bets) {
        my $contract = produce_contract($open_contract->{short_code}, $open_contract->{currency_code});
        next if not $contract->can("trading_period_start");
        next if not $contract->is_intraday;

        my @available_barrier = @{$contract->predefined_contracts->{available_barriers}};

        # Rearrange the index of the barrier from  the median of the barrier list (ie the ATM barrier)
        my %reindex_barrier_list = map { $available_barrier[$_] => $_ - (int @available_barrier / 2) } (0 .. $#available_barrier);
        my $barrier_index        = $reindex_barrier_list{$contract->barrier->as_absolute};
        my $spot                 = $contract->current_spot;
        my ($closest_barrier_to_spot) =
            map { $_->{barrier} } sort { $a->{diff} <=> $b->{diff} } map { {barrier => $_, diff => abs($spot - $_)} } @available_barrier;
        my $spot_index           = $reindex_barrier_list{$closest_barrier_to_spot};
        my $trading_period_start = Date::Utility->new($contract->trading_period_start)->datetime;
        $multibarrier->{$trading_period_start . '_' . $contract->date_expiry->datetime}->{$contract->bet_type}->{barrier}->{$barrier_index}
            ->{$contract->underlying->symbol} +=
            financialrounding('price', 'USD', in_USD($open_contract->{buy_price}, $open_contract->{currency_code}));
        push @{$symbol->{$trading_period_start . '_' . $contract->date_expiry->datetime}}, $contract->underlying->symbol;

        $multibarrier->{$trading_period_start . '_' . $contract->date_expiry->datetime}->{spot}->{$contract->underlying->symbol} = $spot_index;
    }
    my $final;
    foreach my $expiry (sort keys %{$multibarrier}) {
        my $max = 0;

        for (-3 ... 3) {
            $final->{$expiry}->{PUT}->{barrier}->{$_}   = {};
            $final->{$expiry}->{CALLE}->{barrier}->{$_} = {};
            foreach my $symbol (uniq @{$symbol->{$expiry}}) {
                my $CALL = $multibarrier->{$expiry}->{CALLE}->{barrier}->{$_}->{$symbol} // 0;
                my $PUT  = $multibarrier->{$expiry}->{PUT}->{barrier}->{$_}->{$symbol}   // 0;
                $final->{$expiry}->{CALLE}->{barrier}->{$_}->{$symbol}->{'isSpot'} = 1
                    if defined $multibarrier->{$expiry}->{spot}->{$symbol} && $multibarrier->{$expiry}->{spot}->{$symbol} == $_;
                $final->{$expiry}->{PUT}->{barrier}->{$_}->{$symbol}->{'isSpot'} = 1
                    if defined $multibarrier->{$expiry}->{spot}->{$symbol} && $multibarrier->{$expiry}->{spot}->{$symbol} == $_;
                if ($CALL > 0 or $PUT > 0) {
                    if ($CALL > $PUT) {
                        $final->{$expiry}->{CALLE}->{barrier}->{$_}->{$symbol}->{value} = $CALL - $PUT;
                        $final->{$expiry}->{PUT}->{barrier}->{$_}->{$symbol}->{value}   = 0;
                        $max = ($CALL - $PUT) > $max ? $CALL - $PUT : $max;
                    } else {
                        $final->{$expiry}->{PUT}->{barrier}->{$_}->{$symbol}->{value}   = $PUT - $CALL;
                        $final->{$expiry}->{CALLE}->{barrier}->{$_}->{$symbol}->{value} = 0;
                        $max = ($PUT - $CALL) > $max ? $PUT - $CALL : $max;
                    }
                }
            }
        }
        $final->{$expiry}->{max} = $max;
    }

    $final->{generated_time} =  BOM::Database::DataMapper::CollectorReporting->new({broker_code => 'CR'})->get_last_generated_historical_marked_to_market_time;
    return $final;
}

sub closedplreport {
    my $self      = shift;
    my $today = Date::Utility->new;
    my $closed = $self->closed_PL_by_underlying($today->truncate_to_day->db_timestamp);
    my $final;
    foreach my $underlying (keys %$closed) {
        $final->{$underlying}->{usd_closed_pl} = $closed->{$underlying}->{usd_closed_pl};
    }
    $final->{generated_time} = $today->datetime;
use Data::Dumper;
warn Dumper($closed);
    return $final;
}
=head1 METHODS

=head2 generate

Generates the report, ignoring any caching. Returns the report, which is a HashRef.

=cut

sub generate {
    my $self = shift;

    _write_cache($self->_report, 1800);

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
