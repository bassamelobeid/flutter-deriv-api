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

use Mail::Sender;
use BOM::Database::ClientDB;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Product::ContractFactory::Parser qw( shortcode_to_parameters );
use Text::CSV_XS;
use BOM::System::Types;
use Time::Duration::Concise::Localize;

has 'min_contract_length' => (
    isa     => 'bom_time_interval',
    is      => 'ro',
    coerce  => 1,
    default => '1h',
);

# This report will only be run on the MLS.
sub generate {
    my $self = shift;

    my $start = time;

    my $nowish         = $self->end;
    my $pricing_date   = $nowish->minus_time_interval($nowish->epoch % $self->min_contract_length->seconds);
    my $expiry_minimum = $pricing_date->plus_time_interval($self->min_contract_length);

    my $open_bets_ref = $self->live_open_bets;

    my @keys = keys %{$open_bets_ref};

    my $howmany = scalar @keys;

    my $dbh = $self->_db->dbh;

    my $csv = Text::CSV_XS->new({eol => "\n"});
    my ($printed_header, $scenario_header, $scenario_analysis, $sum_of_buyprice, $sum_of_payout);
    my $ignored = 0;
    my %cached_underlyings;
    my $subject          = 'Scenario analysis as of ' . $pricing_date->db_timestamp;
    my $scenario_message = $subject . ":\n\n";
    my $raw_fh           = File::Temp->new(
        dir      => '/tmp/',
        TEMPLATE => 'raw-scenario-' . $pricing_date->time_hhmm . '-XXXXX',
        suffix   => '.csv'
    );
    $csv->print($raw_fh, ['Transaction ID', 'Client ID', 'Shortcode', 'Payout Currency', 'MtM Value']);

    FMB:
    foreach my $open_fmb_id (@keys) {
        my $open_fmb = $open_bets_ref->{$open_fmb_id};
        my ($broker_code) = $open_fmb->{client_loginid} =~ /^([A-Z]+)/;
        next if !grep { $broker_code =~ $_ } qw(CR MLT MX MF);
        my $bet_params = shortcode_to_parameters($open_fmb->{short_code}, $open_fmb->{currency_code});
        $bet_params->{date_pricing} = $pricing_date;
        my $underlying_symbol = $bet_params->{underlying}->symbol;
        $bet_params->{underlying} = $cached_underlyings{$underlying_symbol}
            if ($cached_underlyings{$underlying_symbol});
        my $bet = produce_contract($bet_params);
        if ($bet->is_spread) { next ;}
        $cached_underlyings{$underlying_symbol} ||= $bet->underlying;

        if (   not $bet->underlying->spot
            or $bet->is_expired
            or $bet->date_start->is_after($pricing_date)
            or $bet->date_expiry->is_before($expiry_minimum))
        {
# The above conditions make the risk more liekly to be wrong or out of date by reporting time.
            $ignored++;
            next FMB;
        }

        $csv->print(
            $raw_fh,
            [
                $open_fmb->{transaction_id}, $open_fmb->{client_loginid},
                $open_fmb->{short_code},     $open_fmb->{currency_code},
                $self->amount_in_usd($bet->bid_price, $bet->currency)]);
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
        locale   => BOM::Platform::Context::request()->language
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
    my $sender = Mail::Sender->new({
        smtp    => 'localhost',
        from    => 'Risk reporting <risk-reporting@binary.com>',
        to      => '<x-risk@binary.com>',
        subject => $subject,
    });
    $sender->MailFile({
        msg  => $scenario_message,
        file => [$scenario_fh, $raw_fh],
    });

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
    my $current_vol  = $bet->pricing_args->{iv};
    my $vol_epsilon  = 0.25;
    my %pricing_args = %{$bet->pricing_args};

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
                        pricing_vol   => $vol,
                        current_spot  => $spot
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
