package BOM::Transaction::ContractUpdateHistory;

use strict;
use warnings;

use Moo;
use Finance::Contract::Longcode qw(shortcode_to_parameters);
use Machine::Epsilon;

use BOM::Platform::Context qw(localize);
use BOM::Transaction::Utility;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Product::ContractFactory qw(produce_contract);

has client => (
    is       => 'ro',
    required => 1,
);

sub get_history_by_contract_id {
    my ($self, $args) = @_;

    die 'contract_id is required' unless $args->{contract_id};
    die 'limit is required'       unless $args->{limit};

    my $contract = $args->{contract} // $self->_build_contract({contract_id => $args->{contract_id}});
    my $dm = $self->_fmb_datamapper;

    unless ($contract) {
        return {error => localize('This contract was not found among your open positions.')};
    }

    my $results = $dm->get_multiplier_audit_details_by_contract_id($args->{contract_id}, $args->{limit});

    return $self->_get_history($results, $contract, $args->{limit});
}

sub get_history_by_transaction_id {
    my ($self, $args) = @_;

    die 'transaction_id is required' unless $args->{transaction_id};
    die 'limit is required'          unless $args->{limit};

    my $contract = $args->{contract} // $self->_build_contract({transaction_id => $args->{transaction_id}});
    my $dm = $self->_fmb_datamapper;

    unless ($contract) {
        return {error => localize('This contract was not found among your open positions.')};
    }

    my $results = $dm->get_multiplier_audit_details_by_transaction_id($args->{transaction_id}, $args->{limit});

    return $self->_get_history($results, $contract, $args->{limit});
}

sub _get_history {
    my ($self, $results, $contract, $limit) = @_;

    my @history;
    my $prev;
    OUTER:
    for (my $i = 0; $i <= $#$results; $i++) {
        my $current = $results->[$i];
        foreach my $order_type (@{$contract->category->allowed_update}) {
            next unless $current->{$order_type . '_order_date'};
            my $order_amount_str = $order_type . '_order_amount';
            my $display_name = $order_type eq 'take_profit' ? localize('Take profit') : localize('Stop loss');
            my $order_amount;
            unless ($prev) {
                $order_amount = $current->{$order_amount_str} ? $current->{$order_amount_str} + 0 : 0;
            } else {
                if (defined $prev->{$order_amount_str} and defined $current->{$order_amount_str}) {
                    next if (abs($prev->{$order_amount_str} - $current->{$order_amount_str}) <= machine_epsilon());
                    $order_amount = $current->{$order_amount_str} + 0;
                } elsif (defined $prev->{$order_amount_str}) {
                    $order_amount = 0;
                } elsif (defined $current->{$order_amount_str}) {
                    $order_amount = $current->{$order_amount_str} + 0;
                }
            }

            push @history,
                +{
                display_name => $display_name,
                order_amount => $order_amount,
                order_date   => Date::Utility->new($current->{$order_type . '_order_date'})->epoch,
                value        => $contract->new_order({$order_type => abs($order_amount)})->barrier_value,
                order_type   => $order_type,
                }
                if (defined $order_amount);

            last OUTER if $limit == scalar @history;
        }
        $prev = $current;
    }

    return [@history];
}

sub _build_contract {
    my ($self, $args) = @_;

    return undef unless $self->client->default_account;

    my $fmb_dm     = $self->_fmb_datamapper;
    my $account_id = $self->client->default_account->id;
    my $fmb =
          $args->{transaction_id} ? $fmb_dm->get_contract_by_account_id_transaction_id($account_id, $args->{transaction_id})->[0]
        : $args->{contract_id} ? $fmb_dm->get_contract_by_account_id_contract_id($account_id, $args->{contract_id})->[0]
        :                        die 'only support _build_contract with contract_id or transaction_id';

    return undef unless $fmb;

    my $contract_params = shortcode_to_parameters($fmb->{short_code}, $self->client->currency);
    my $limit_order = BOM::Transaction::Utility::extract_limit_orders($fmb);
    $contract_params->{limit_order} = $limit_order if %$limit_order;

    $contract_params->{is_sold}    = $fmb->{is_sold};
    $contract_params->{sell_time}  = $fmb->{sell_time} if $fmb->{sell_time};
    $contract_params->{sell_price} = $fmb->{sell_price} if $fmb->{sell_price};

    return produce_contract($contract_params);
}

has _fmb_datamapper => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_fmb_datamapper',
);

sub _build_fmb_datamapper {
    my $self = shift;

    return BOM::Database::DataMapper::FinancialMarketBet->new(
        broker_code => $self->client->broker_code,
        operation   => 'replica',
    );
}
1;
