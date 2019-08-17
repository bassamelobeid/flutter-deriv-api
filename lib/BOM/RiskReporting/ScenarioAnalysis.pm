package BOM::RiskReporting::ScenarioAnalysis;

=head1 NAME

BOM::Product:RiskReporting::ScenarioAnalysis

=head1 SYNOPSIS

BOM::RiskReport::ScenarioAnalysis->new->generate;

=cut

use 5.010;
use strict;
use warnings;

local $\ = undef;    # Sigh.

use Moose;
extends 'BOM::RiskReporting::Base';

use IO::File;
use IO::Handle;
use File::Path qw(make_path);
use File::Temp;
use List::Util qw(min sum);
use Email::Address::UseXS;
use Email::Stuffer;
use Text::CSV_XS;
use Time::Duration::Concise::Localize;
use Try::Tiny;
use BOM::Database::ClientDB;
use BOM::Product::ContractFactory qw( produce_contract );
use Finance::Contract::Longcode qw( shortcode_to_parameters );
use BOM::MarketData::Types;
use BOM::Backoffice::Request;
use Date::Utility;
use Volatility::EconomicEvents;
use BOM::Config::Chronicle;
use Quant::Framework::EconomicEventCalendar;

has 'min_contract_length' => (
    isa     => 'time_interval',
    is      => 'ro',
    coerce  => 1,
    default => '1h',
);

# This report will only be run on the MLS.
sub generate {
    my $self     = shift;
    my $for_date = shift;

    my $start = time;
    my $events;
    if ($for_date) {

        my $seasonality_prefix = 'bo_' . time . '_';
        Volatility::EconomicEvents::set_prefix($seasonality_prefix);
        my $EEC = Quant::Framework::EconomicEventCalendar->new({
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(1),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        });

        my $for_date_obj = Date::Utility->new($for_date);

        $events = $EEC->get_latest_events_for_period({
                from => $for_date_obj,
                to   => $for_date_obj->plus_time_interval('6d'),
            },
            $for_date_obj
        );
    }

    my $nowish         = Date::Utility->new($for_date) || Date::Utility->new;
    my $pricing_date   = $nowish->minus_time_interval($nowish->epoch % $self->min_contract_length->seconds);
    my $expiry_minimum = $pricing_date->plus_time_interval($self->min_contract_length);
    my $open_bets_ref  = $for_date ? $self->historical_open_bets($nowish->date) : $self->live_open_bets;
    my @keys           = keys %{$open_bets_ref};
    my $howmany        = scalar @keys;

    my $csv = Text::CSV_XS->new({eol => "\n"});
    my ($scenario_analysis, $sum_of_buyprice, $sum_of_payout);
    my $ignored          = 0;
    my $subject          = 'Scenario analysis as of ' . $pricing_date->db_timestamp;
    my $scenario_message = $subject . ":\n\n";
    my $raw_fh           = File::Temp->new(
        dir      => '/tmp/',
        TEMPLATE => 'raw-scenario-' . $pricing_date->time_hhmm . '-XXXXX',
        suffix   => '.csv'
    );
    my $ignored_fh = File::Temp->new(
        dir      => '/tmp/',
        TEMPLATE => 'ignored-scenario-' . $pricing_date->time_hhmm . '-XXXXX',
        suffix   => '.csv'
    );

    $csv->print($ignored_fh, ['Transaction ID', 'Client ID', 'Shortcode', 'Payout Currency', 'Reason']);
    $csv->print($raw_fh,     ['Transaction ID', 'Client ID', 'Shortcode', 'Payout Currency', 'MtM Value']);
    FMB:
    foreach my $open_fmb_id (@keys) {
        my $open_fmb = $open_bets_ref->{$open_fmb_id};
        my ($broker_code) = $open_fmb->{client_loginid} =~ /^([A-Z]+)/;
        next if !grep { $broker_code =~ $_ } qw(CR MLT MX MF);
        my $bet_params = shortcode_to_parameters($open_fmb->{short_code}, $open_fmb->{currency_code});
        $bet_params->{date_pricing} = $pricing_date;
        my ($bet, $underlying, $bid_price);

        try {
            $bet        = produce_contract($bet_params);
            $underlying = $bet->underlying;
            $bid_price  = $bet->bid_price;
            # We need to make sure that we return a true value here, since
            # we use the result of the try/catch block to decide whether to
            # proceed
            1;
        }
        catch {
            my $err = $_;
            $err = $err->{error_code} if ref($err) eq 'HASH' and exists $err->{error_code};

            $ignored++;
            $csv->print($ignored_fh,
                [$open_fmb->{transaction_id}, $open_fmb->{client_loginid}, $open_fmb->{short_code}, $open_fmb->{currency_code}, $err]);
            # Make sure the catch sub returns zero so we skip any further processing
            0;
        } or next FMB;

        my $underlying_symbol = $underlying->symbol;
        my $bid_price_in_usd = $self->amount_in_usd($bid_price, $bet->currency);
        if (   not $bet->underlying->spot
            or $bet->is_expired
            or $bet->date_start->is_after($pricing_date)
            or $bet->date_expiry->is_before($expiry_minimum))
        {
# The above conditions make the risk more liekly to be wrong or out of date by reporting time.
            $ignored++;
            $csv->print(
                $ignored_fh,
                [
                    $open_fmb->{transaction_id}, $open_fmb->{client_loginid}, $open_fmb->{short_code},
                    $open_fmb->{currency_code},  $bid_price_in_usd,           'Out_of_scope'
                ]);

            next FMB;
        }
        if ($for_date) {

            Volatility::EconomicEvents::generate_variance({

                    underlying_symbols => [$underlying_symbol],
                    economic_events    => $events,
                    date               => $bet->date_start,
                    chronicle_writer   => BOM::Config::Chronicle::get_chronicle_writer(),
            });

        }
        $csv->print($raw_fh,
            [$open_fmb->{transaction_id}, $open_fmb->{client_loginid}, $open_fmb->{short_code}, $open_fmb->{currency_code}, $bid_price_in_usd]);
        my @prices_in_usd = $self->_calculate_grid_for_max_exposure($bet);

        my $usd_buy_price = $self->amount_in_usd($open_fmb->{buy_price}, $bet->currency);
        $sum_of_buyprice->{$broker_code} //= 0;
        $sum_of_buyprice->{$broker_code} += $usd_buy_price;

        my $usd_payout = $self->amount_in_usd($bet->payout, $bet->currency);
        $sum_of_payout->{$broker_code} //= 0;
        $sum_of_payout->{$broker_code} += $usd_payout;

        my @pnls = map { $usd_buy_price - $_ } @prices_in_usd;
        my @pnls_sum =
            ($scenario_analysis->{$broker_code}->{$underlying_symbol})
            ? @{$scenario_analysis->{$broker_code}->{$underlying_symbol}}
            : (0) x 14;
        my @new_pnls = map { $pnls[$_] + $pnls_sum[$_] } (0 .. $#pnls_sum);
        $scenario_analysis->{$broker_code}->{$underlying_symbol} = \@new_pnls;

    }
    $raw_fh->flush;
    my ($total_payout, $total_buyprice, $total_risk) = (0) x 3;
    foreach my $broker_code (keys %$sum_of_payout) {
        my @prices          = values %{$scenario_analysis->{$broker_code}};
        my @new_sum         = sum map { min @$_ } @prices;
        my $risk_per_broker = min(@new_sum);
        $scenario_message .= format_report($broker_code, $sum_of_payout->{$broker_code}, $sum_of_buyprice->{$broker_code}, $risk_per_broker);
        $total_payout   += $sum_of_payout->{$broker_code};
        $total_buyprice += $sum_of_buyprice->{$broker_code};
        $total_risk     += $risk_per_broker;
    }

    $scenario_message .= format_report("Combined", $total_payout, $total_buyprice, $total_risk);

    my $scenario_fh = File::Temp->new(
        dir      => '/tmp/',
        TEMPLATE => 'scenario-' . $pricing_date->time_hhmm . '-XXXXX',
        suffix   => '.csv'
    );
    $csv->print(
        $scenario_fh,
        [
            'Underlying Symbol', 'Broker',  '-8s-25v',   '-5.3s-25v', '-2.6s-25v', '0s-25v',    '+2.6s-25v', '+5.3s-25v',
            '+8s-25v',           '-8s+25v', '-5.3s+25v', '-2.6s+25v', '0s+25v',    '+2.6s+25v', '+5.3s+25v', '+8s+25v'
        ]);    # This is not true.
    foreach my $broker_code (keys %$scenario_analysis) {
        foreach my $underlying_symbol (keys %{$scenario_analysis->{$broker_code}}) {
            my @output =
                @{$scenario_analysis->{$broker_code}->{$underlying_symbol}};
            $csv->print($scenario_fh, [$underlying_symbol, $broker_code, @output]);
        }
    }
    $scenario_fh->flush;
    my $howlong = Time::Duration::Concise::Localize->new(
        interval => time - $start,
        locale   => BOM::Backoffice::Request::request()->language
    );
    my $status =
          'Total run time ['
        . $howlong->as_string
        . '] for ['
        . ($howmany - $ignored)
        . '] positions ['
        . $ignored
        . '] out of scope contracts ignored.';
    $scenario_message .= "\n\n" . $status;
    my $brand = BOM::Backoffice::Request::request()->brand;
    Email::Stuffer->from('Risk reporting ' . $brand->emails('risk_reporting'))->to($brand->emails('risk'))->subject($subject)
        ->text_body($scenario_message)->attach_file($scenario_fh->filename)->attach_file($raw_fh->filename)->send;
    return;
}

sub format_report {
    my ($label, $payout, $buy, $risk) = @_;

    return "\n" . $label . ":\n\nTotal Payout: " . $payout . "\nTotal Buy Price: " . $buy . "\nTotal Risk: " . $risk . "\n===\n";
}

sub _calculate_grid_for_max_exposure {
    my ($self, $bet) = @_;

    my $current_spot = $bet->current_spot;
    my $spot_epsilon = ($bet->market->name eq 'commodities' and not $bet->underlying->symbol eq 'frxXAUUSD') ? 0.15 : 0.08;
    my $current_vol  = $bet->_pricing_args->{iv};
    my $vol_epsilon  = 0.25;

    my @prices;
    my %params = %{$bet->build_parameters};
    foreach my $vol (($current_vol * (1 - $vol_epsilon), $current_vol * (1 + $vol_epsilon))) {

        for (
            my $spot = $current_spot * (1 - $spot_epsilon);
            $spot <= $current_spot * (1 + $spot_epsilon) + 0.001;
            $spot = $spot + $current_spot * ($spot_epsilon / 3))
        {
            push @prices,
                $self->amount_in_usd(
                produce_contract(
                    +{
                        %params,
                        pricing_vol  => $vol,
                        current_spot => $spot
                    }
                    )->bid_price,
                $bet->currency
                );
        }
    }

    return @prices;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
