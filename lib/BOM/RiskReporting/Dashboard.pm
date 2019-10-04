package BOM::RiskReporting::Dashboard;

=head1 NAME

BOM::RiskReporting::Dashboard

=head1 DESCRIPTION

Generates the report shown on our Risk Dashboard b/o page.

=cut

use strict;
use warnings;

use IO::File;
use List::Util qw(max first sum reduce sum0);
use List::UtilsBy qw(rev_nsort_by);
use JSON::MaybeXS;
use Moose;
use Try::Tiny;
use Math::BigFloat;
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
use BOM::Config::Runtime;
use BOM::Backoffice::Request;
use List::MoreUtils qw(uniq);
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Product::Contract::PredefinedParameters;
use ExchangeRates::CurrencyConverter qw(in_usd);
use BOM::MarketData qw(create_underlying);
use LandingCompany::Registry;
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
    return $json->decode(BOM::Config::Runtime->instance->app_config->quants->custom_client_profiles);
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
    $report->{generated_time}  = Date::Utility->new->plus_time_interval(($ttl - 1800) . 's')->datetime;

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
    my @sorted_financial =
        sort { $b->{financial_turnover} <=> $a->{financial_turnover} }
        map { $self->_do_name_plus($tops->{$_}) } (keys %$tops);
    my @sorted_non_financial =
        sort { $b->{non_financial_turnover} <=> $a->{non_financial_turnover} }
        map { $self->_do_name_plus($tops->{$_}) } (keys %$tops);

    return {
        financial     => [(scalar @sorted_financial <= 10)     ? @sorted_financial     : @sorted_financial[0 .. 9]],
        non_financial => [(scalar @sorted_non_financial <= 10) ? @sorted_non_financial : @sorted_non_financial[0 .. 9]],
    };
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

    my @financial_winners     = sort { $b->{usd_financial_profit} <=> $a->{usd_financial_profit} } @movers;
    my @financial_losers      = reverse @financial_winners;
    my @non_financial_winners = sort { $b->{usd_non_financial_profit} <=> $a->{usd_non_financial_profit} } @movers;
    my @non_financial_losers  = reverse @non_financial_winners;
    my (@big_financial_winners, @big_non_financial_winners, @big_financial_losers, @big_non_financial_losers, @watched);

    for my $i (0 .. 9) {
        push @big_financial_winners, $financial_winners[$i]
            if ($financial_winners[$i] and $financial_winners[$i]->{usd_financial_profit} > 0);
        push @big_non_financial_winners, $non_financial_winners[$i]
            if ($non_financial_winners[$i] and $non_financial_winners[$i]->{usd_non_financial_profit} > 0);
        push @big_financial_losers, $financial_losers[$i]
            if ($financial_losers[$i] and $financial_losers[$i]->{usd_financial_profit} < 0);
        push @big_non_financial_losers, $non_financial_losers[$i]
            if ($non_financial_losers[$i] and $non_financial_losers[$i]->{usd_non_financial_profit} < 0);
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

    foreach my $watch (@watched) {
        $watch->{profit} = List::Util::sum0 map { $watch->{$_} // 0 } qw(financial_profit non_financial_profit);
    }

    return {
        big_deposits    => \@big_deposits,
        big_withdrawals => \@big_withdrawals,
        big_winners     => {
            financial     => \@big_financial_winners,
            non_financial => \@big_non_financial_winners,
        },
        big_losers => {
            financial     => \@big_financial_losers,
            non_financial => \@big_non_financial_losers,
        },
        watched => \@watched,
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
        my $spot_index = $reindex_barrier_list{$closest_barrier_to_spot};
        $multibarrier->{$contract->date_expiry->datetime}->{$contract->bet_type}->{barrier}->{$barrier_index}->{$contract->underlying->symbol} +=
            financialrounding('price', 'USD', in_usd($open_contract->{payout_price}, $open_contract->{currency_code}));
        push @{$symbol->{$contract->date_expiry->datetime}}, $contract->underlying->symbol;

        $multibarrier->{$contract->date_expiry->datetime}->{spot}->{$contract->underlying->symbol} = $spot_index;
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
                        my $isOTM = $multibarrier->{$expiry}->{spot}->{$symbol} < $_ ? 1 : 0;
                        $final->{$expiry}->{CALLE}->{barrier}->{$_}->{$symbol}->{isOTM} = $isOTM;
                    } else {
                        $final->{$expiry}->{PUT}->{barrier}->{$_}->{$symbol}->{value}   = $PUT - $CALL;
                        $final->{$expiry}->{CALLE}->{barrier}->{$_}->{$symbol}->{value} = 0;
                        my $isOTM = $multibarrier->{$expiry}->{spot}->{$symbol} > $_ ? 1 : 0;
                        $final->{$expiry}->{PUT}->{barrier}->{$_}->{$symbol}->{isOTM} = $isOTM;
                        $max = ($PUT - $CALL) > $max ? $PUT - $CALL : $max;
                    }
                }
            }
        }
        $final->{$expiry}->{max} = $max;
    }

    $final->{generated_time} = $self->_report_mapper->get_last_generated_historical_marked_to_market_time;
    return $final;
}

sub open_contract_exposures {
    my $self      = shift;
    my @open_bets = @{$self->_open_bets_at_end};
    my $final;
    foreach my $open_contract (@open_bets) {
        my $broker;
        if ($open_contract->{loginid} =~ /^(\D+)\d/) {
            $broker = $1;
        }
        my $contract = produce_contract($open_contract->{short_code}, $open_contract->{currency_code});

        my $purchase_price = financialrounding('price', 'USD', in_usd($open_contract->{buy_price},    $open_contract->{currency_code}));
        my $payout_price   = financialrounding('price', 'USD', in_usd($open_contract->{payout_price}, $open_contract->{currency_code}));
        my $expiry_type = $contract->is_intraday  ? 'intraday' : 'daily';
        my $category    = ($contract->is_atm_bet) ? 'atm'      : 'non_atm';

        foreach my $br ($broker, "ALL") {
            $final->{$br}->{$contract->underlying->market->name}->{$expiry_type}->{$category}->{total_turnover} += $purchase_price;
            $final->{$br}->{$contract->underlying->market->name}->{$expiry_type}->{$category}->{total_payout}   += $payout_price;
            $final->{$br}->{$contract->underlying->market->name}->{$expiry_type}->{total_turnover}              += $purchase_price;
            $final->{$br}->{$contract->underlying->market->name}->{$expiry_type}->{total_payout}                += $payout_price;
            $final->{$br}->{$contract->underlying->market->name}->{$expiry_type}->{$category}->{$contract->underlying->symbol}->{total_turnover} +=
                $purchase_price;
            $final->{$br}->{$contract->underlying->market->name}->{$expiry_type}->{$category}->{$contract->underlying->symbol}->{total_payout} +=
                $payout_price;
            $final->{$br}->{total_turnover}                                        += $purchase_price;
            $final->{$br}->{total_payout}                                          += $payout_price;
            $final->{$br}->{$contract->underlying->market->name}->{total_turnover} += $purchase_price;
            $final->{$br}->{$contract->underlying->market->name}->{total_payout}   += $payout_price;
        }
    }
    my $report;
    $report->{pl} = sorting_data($final, 'open_bet');
    $report->{generated_time} = $self->_report_mapper->get_last_generated_historical_marked_to_market_time;

    return $report;
}

sub closed_contract_exposures {
    my $self   = shift;
    my $date   = shift;
    my $closed = $self->closed_PL_by_underlying($date->truncate_to_day->db_timestamp);
    my $summary;
    foreach my $i (keys @{$closed}) {
        my $broker      = $closed->[$i][0];
        my $underlying  = $closed->[$i][1];
        my $market      = create_underlying($underlying)->market->name;
        my $expiry_type = $closed->[$i][2] == 1 ? 'daily' : 'intraday';
        my $atm_type    = $closed->[$i][3] == 1 ? 'atm' : 'non_atm';
        my $closed_pl   = financialrounding('price', 'USD', $closed->[$i][4]);
        foreach my $br ($broker, "ALL") {
            $summary->{$br}->{$market}->{total_closed_pl}                                             += $closed_pl;
            $summary->{$br}->{$market}->{$expiry_type}->{total_closed_pl}                             += $closed_pl;
            $summary->{$br}->{$market}->{$expiry_type}->{$atm_type}->{total_closed_pl}                += $closed_pl;
            $summary->{$br}->{$market}->{$expiry_type}->{$atm_type}->{$underlying}->{total_closed_pl} += $closed_pl;
            $summary->{$br}->{total_closed_pl}                                                        += $closed_pl;
        }
    }
    my $report;
    $report->{pl} = sorting_data($summary, 'closed_pl');
    $report->{generated_time} = Date::Utility->new->datetime;
    return $report;

}

sub sorting_data {
    my ($final, $for) = @_;
    my $sorting_arg = $for eq 'open_bet' ? 'total_payout' : 'total_closed_pl';
    foreach my $broker (keys %{$final}) {
        foreach my $market (keys %{$final->{$broker}}) {
            if ($market =~ /total/) {
                $final->{$broker}->{$market} = financialrounding('price', 'USD', $final->{$broker}->{$market});
                next;
            }
            foreach my $expiry (keys %{$final->{$broker}->{$market}}) {
                if ($expiry =~ /total/) {
                    $final->{$broker}->{$market}->{$expiry} = financialrounding('price', 'USD', $final->{$broker}->{$market}->{$expiry});
                    next;
                }
                foreach my $atm (keys %{$final->{$broker}->{$market}->{$expiry}}) {
                    if ($atm =~ /total/) {
                        $final->{$broker}->{$market}->{$expiry}->{$atm} =
                            financialrounding('price', 'USD', $final->{$broker}->{$market}->{$expiry}->{$atm});
                        next;
                    }
                    my @sorted_by_underlying = $for eq 'open_bet'
                        ? map { [
                            $_,
                            $final->{$broker}->{$market}->{$expiry}->{$atm}->{$_}->{total_payout},
                            $final->{$broker}->{$market}->{$expiry}->{$atm}->{$_}->{total_turnover}]
                        }
                        rev_nsort_by {
                        $final->{$broker}->{$market}->{$expiry}->{$atm}->{$_}->{total_payout}
                    }
                    grep { $_ !~ /total/ } keys %{$final->{$broker}->{$market}->{$expiry}->{$atm}}
                        : map { [$_, $final->{$broker}->{$market}->{$expiry}->{$atm}->{$_}->{total_closed_pl}] }
                        rev_nsort_by {
                        $final->{$broker}->{$market}->{$expiry}->{$atm}->{$_}->{total_closed_pl}
                    }
                    grep { $_ ne 'total_closed_pl' } keys %{$final->{$broker}->{$market}->{$expiry}->{$atm}};

                    for (my $i = 0; $i < scalar @sorted_by_underlying; $i++) {
                        delete $final->{$broker}->{$market}->{$expiry}->{$atm}->{$sorted_by_underlying[$i][0]};
                        if ($for eq 'open_bet') {
                            $final->{$broker}->{$market}->{$expiry}->{$atm}->{$i}->{$sorted_by_underlying[$i][0]} = {
                                total_payout   => financialrounding('price', 'USD', $sorted_by_underlying[$i][1]),
                                total_turnover => financialrounding('price', 'USD', $sorted_by_underlying[$i][2])};
                        } else {
                            $final->{$broker}->{$market}->{$expiry}->{$atm}->{$i}->{$sorted_by_underlying[$i][0]}->{total_closed_pl} =
                                financialrounding('price', 'USD', $sorted_by_underlying[$i][1]);
                        }
                    }
                }
            }
        }
    }

    my $report;
    foreach my $broker (keys %{$final}) {
        my @sorted_market =
            map { [$_, $final->{$broker}->{$_}] } rev_nsort_by { $final->{$broker}->{$_}->{$sorting_arg} }
        grep { $_ !~ /total/ } keys %{$final->{$broker}};
        for (my $i = 0; $i < scalar @sorted_market; $i++) { $report->{$broker}->{$i} = {$sorted_market[$i][0] => $sorted_market[$i][1]}; }
        # this is to put the total of each broker
        map { $report->{$broker}->{$_} = $final->{$broker}->{$_} } grep { $_ =~ /total/ } keys %{$final->{$broker}};

    }
    my $final_report;
    my @sorted_broker = ['ALL', $report->{'ALL'}];
    push @sorted_broker, map { [$_, $report->{$_}] } rev_nsort_by { $report->{$_}->{$sorting_arg} } grep { $_ ne 'ALL' } keys %{$report};
    for (my $i = 0; $i < scalar @sorted_broker; $i++) { $final_report->{$i} = {$sorted_broker[$i][0] => $sorted_broker[$i][1]}; }
    return $final_report;
}

sub exposures_report {
    my $self = shift;
    my $report;
    my $date = Date::Utility->new;
    $report->{open_bet}           = $self->open_contract_exposures();
    $report->{closed_pl}          = $self->closed_contract_exposures($date);
    $report->{previous_closed_pl} = $self->closed_contract_exposures($date->minus_time_interval('1d'));
    return $report;
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
