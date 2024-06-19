package BOM::RiskReporting::VanillaRiskReporting;

use Moose;
extends 'BOM::RiskReporting::Dashboard';

use Finance::Contract::Longcode      qw(shortcode_to_parameters);
use BOM::Product::ContractFactory    qw(produce_contract);
use Format::Util::Numbers            qw(financialrounding);
use List::Util                       qw(min max);
use ExchangeRates::CurrencyConverter qw(in_usd);
use Scalar::Util                     qw(looks_like_number);
use YAML::XS                         qw(LoadFile);
use Test::MockModule;

=head2 get_vanilla_risk_reporting_config

Helper function to get the config for vanilla risk reporting

=cut

sub get_vanilla_risk_reporting_config {
    return LoadFile('/home/git/regentmarkets/bom-backoffice/config/vanilla_risk_reporting.yml');
}

=head2 vanilla_risk_report

Generates a report of the risk metric of all open vanilla bets
The logic of this method is as follow:
1) Get all vanilla open bets
2) For each open bet, calculate the following risk metric based on hypothetical spot price change scenarios
    - profit and loss (pnl)
    - number of contracts
    - intrinsic value
    - extrinsic value
    - 1 day theta
    - delta
    - gamma
3) The result is in a hash with structure as follow
    result => {
        R_10 => {
            pnl => {
                "less than a day" => {
                                        contract_id_1  => [ 0 0.1 0.2 0.3 0.4 0.5 ],
                                        contract_id_2  => [ 0 0.1 0.2 0.3 0.4 0.5 ],
                                     },
                "1 to 2 weeks"    => {
                                        contract_id_1  => [ 0 0.1 0.2 0.3 0.4 0.5 ],
                                        contract_id_2  => [ 0 0.1 0.2 0.3 0.4 0.5 ],
                                      },
                    },
            number_of_contracts => { ... },
            intrinsic_value     => { ... }
            ...
        }
        R_25 => { ... },
        R_50 => { ... },
        frxAUDUSD => {...},
    }
4) The result is then aggregated by each risk metric, aggregated result is in this structure
    aggregated_result => {
        R_10 => {
            spot_scenario => [1000, 2000, 3000, 4000, 5000, 6000],
            pnl           => {
                                "less than a day" => {
                                                        contract_ids  => [ contract_id_1 contract_id_2 ],
                                                        values        => [ 0 0.2 0.4 0.6 0.8 1.0 ],
                                                     },
                                "1 to 2 weeks"    => {
                                                        contract_ids  => [ contract_id_1 contract_id_2 ],
                                                        values        => [ 0 0.2 0.4 0.6 0.8 1.0 ],
                                                      },
                            },
            number_of_contracts => { ... },
            intrinsic_value     => { ... }
            ...
        },
        R_25 => { ... },
        R_50 => { ... },
        frxAUDUSD => {...},

    }

=cut

sub vanilla_risk_report {

    my ($self, $at_date) = @_;

    my $open_bets = $self->_open_bets_at_end(Date::Utility->new($at_date));

    $open_bets = [grep { $_->{bet_class} eq 'vanilla' } @$open_bets];

    my ($result, $current_spot_for);
    my $cfg = get_vanilla_risk_reporting_config();

    my @spot_change_scenarios = $cfg->{spot_change_scenarios}->@*;

    foreach my $open_contract (@$open_bets) {
        my $broker;
        $broker = $1 if ($open_contract->{loginid} =~ /^(\D+)\d/);

        my $bet_params = shortcode_to_parameters($open_contract->{short_code}, $open_contract->{currency_code});

        $bet_params->{date_pricing} = $at_date // $self->end;

        my $contract_id = $open_contract->{id};
        my $contract    = produce_contract($bet_params);

        my $spot        = $contract->current_spot;
        my $epoch       = $contract->current_tick->epoch;
        my $symbol      = $contract->underlying->symbol;
        my $time_remain = $contract->timeinyears->amount;

        my (@number_of_contracts_row, @pnl_row, @delta_row, @gamma_row, @intrinsic_value, @extrinsic_value, @theta);
        my @current_spot_change_scenarios = map { financialrounding('price', 'USD', $_ * $spot) } @spot_change_scenarios;

        $current_spot_for->{$symbol} = $spot;
        foreach my $spot_change (@current_spot_change_scenarios) {
            my $mock = Test::MockModule->new('BOM::Product::Contract');
            $mock->mock('current_tick', sub { Postgres::FeedDB::Spot::Tick->new({quote => $spot_change, epoch => $epoch}) });
            $mock->mock('pricing_spot', sub { return $spot_change });
            $mock->mock('current_spot', sub { return $spot_change });

            my $metrics = calculate_risk_metrics($contract, $spot_change);

            push @pnl_row,                 $metrics->{pnl};
            push @number_of_contracts_row, $metrics->{number_of_contracts};
            push @intrinsic_value,         $metrics->{intrinsic_value};
            push @extrinsic_value,         $metrics->{extrinsic_value};
            push @theta,                   $metrics->{theta};
            push @delta_row,               $metrics->{delta};
            push @gamma_row,               $metrics->{gamma};
        }

        my $time_remain_bin = get_readable_tenor($time_remain);

        $result->{$symbol}->{pnl}->{$time_remain_bin}->{$contract_id}                 = \@pnl_row;
        $result->{$symbol}->{number_of_contracts}->{$time_remain_bin}->{$contract_id} = \@number_of_contracts_row;
        $result->{$symbol}->{intrinsic_value}->{$time_remain_bin}->{$contract_id}     = \@intrinsic_value;
        $result->{$symbol}->{extrinsic_value}->{$time_remain_bin}->{$contract_id}     = \@extrinsic_value;
        $result->{$symbol}->{theta}->{$time_remain_bin}->{$contract_id}               = \@theta;
        $result->{$symbol}->{delta}->{$time_remain_bin}->{$contract_id}               = \@delta_row;
        $result->{$symbol}->{gamma}->{$time_remain_bin}->{$contract_id}               = \@gamma_row;

    }

    my $aggregated_result;
    foreach my $symbol (keys $result->%*) {
        # ideally this should be pipsized but at the magnitude of changes here it doesn't matter
        my @spot_scenario = map { sprintf("%.2f", $_ * $current_spot_for->{$symbol}) } @spot_change_scenarios;
        $aggregated_result->{$symbol}->{spot_scenario} = \@spot_scenario;
        foreach my $metric (sort keys $result->{$symbol}->%*) {
            my $entry = $result->{$symbol}->{$metric};

            foreach my $time_remain (sort keys $entry->%*) {

                my @sum;
                foreach my $contract (keys $entry->{$time_remain}->%*) {
                    my @data = $entry->{$time_remain}->{$contract}->@*;
                    foreach my $i (0 .. $#data) {
                        $sum[$i] += $data[$i];
                    }

                }
                # add contract id array into the string like "59, 79"
                $aggregated_result->{$symbol}->{$metric}->{$time_remain}->{'values'} = \@sum;

                my @contract_ids = (keys $entry->{$time_remain}->%*);
                @contract_ids = grep { looks_like_number($_) } @contract_ids if @contract_ids > 1;
                $aggregated_result->{$symbol}->{$metric}->{$time_remain}->{'contract_ids'} = join(', ', @contract_ids);

            }
        }

    }
    return $aggregated_result;
}

=head2 calculate_risk_metrics

Calculate pnl, delta, gamma, theta, number_of_contracts, intrinsic_value, extrinsic_value for a given contract and spot price change
All the risk metrics are from company's perspective

=cut

sub calculate_risk_metrics {
    my ($contract, $spot_change) = @_;

    my $currency            = $contract->currency;
    my $time_remain         = $contract->timeinyears->amount;
    my $number_of_contracts = $contract->number_of_contracts;
    $number_of_contracts = $number_of_contracts / $contract->underlying->pip_size unless $contract->is_synthetic;
    my $strike_spot_diff = ($contract->code eq 'VANILLALONGPUT' ? -1 : 1) * ($contract->barrier->as_absolute - $spot_change);

    $contract->_pricing_args->{spot} = $spot_change;
    $contract->_pricing_args->{t}    = $time_remain;
    my $new_bid_price = $contract->_build_bid_probability->amount * $number_of_contracts;

    $contract->_pricing_args->{t} = $time_remain - 1 / 365 if $time_remain > 1 / 365;
    my $old_bid_price = $contract->_build_bid_probability->amount * $number_of_contracts;

    #undo number_of_contracts modification
    $number_of_contracts = $number_of_contracts * $contract->underlying->pip_size unless $contract->is_synthetic;

    my $contract_greeks = $contract->_build_greek_engine;
    my $pnl             = -1 * ($new_bid_price - $contract->_user_input_stake);
    my $intrinsic_value = min(0, $number_of_contracts * ($strike_spot_diff));
    my $extrinsic_value = -1 * max(0, abs($new_bid_price) - abs($intrinsic_value));    # dealing team doesn't want to see positive extrinsic value
    my $theta           = $new_bid_price - $old_bid_price;
    my $delta           = -1 * $contract_greeks->delta * $number_of_contracts;
    my $gamma           = -1 * $contract_greeks->gamma * $number_of_contracts;
    $number_of_contracts = 0 unless $intrinsic_value;                                  # we just want to show number of contracts for ITM contracts

    return {
        pnl                 => sprintf("%.4f", in_usd($pnl, $currency)),
        number_of_contracts => sprintf("%.4f", $number_of_contracts),
        intrinsic_value     => sprintf("%.4f", in_usd($intrinsic_value, $currency)),
        extrinsic_value     => sprintf("%.4f", in_usd($extrinsic_value, $currency)),
        theta               => sprintf("%.4f", in_usd($theta,           $currency)),
        delta               => sprintf("%.4f", $delta),
        gamma               => sprintf("%.4f", $gamma),
    };
}

=head2 get_readable_tenor

convert annualized tenor to human readable form
i.e. 0.00273 -> less than a day

=cut

sub get_readable_tenor {
    my $tenor = shift;

    my $cfg              = get_vanilla_risk_reporting_config();
    my @time_remain_bins = $cfg->{time_remain_bins}->@*;

    foreach my $i (0 .. $#time_remain_bins) {
        my $bin = $time_remain_bins[$i];
        if (!defined $bin->{max} || $tenor < $bin->{max}) {
            return $bin->{label};
        }
    }

}
