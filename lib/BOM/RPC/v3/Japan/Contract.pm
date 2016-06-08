package BOM::RPC::v3::Japan::Contract;

use strict;
use warnings;

use BOM::Market::UnderlyingDB;
use BOM::RPC::v3::Utility;
use BOM::Platform::Context qw(localize);
use BOM::System::RedisReplicated;
use Format::Util::Numbers qw(roundnear);

sub validate_table_props {

    my $args = shift;

    if (ref $args ne 'HASH') {
        return {
            error => {
                code    => 'WrongPricingTableargs',
                message => "Wrong pricing table arguments",
            }};
    }

    my %symbols = map { $_ => 1 } BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market    => 'forex',
        submarket => 'major_pairs'
    );

    # Japan has only Forex/Major-pairs contracts
    if (not defined $args->{symbol} or not $symbols{$args->{symbol}}) {
        return {
            error => {
                code    => 'InvalidSymbol',
                message => "Symbol [_1] invalid",
                params  => [$args->{symbol}],
            }};
    }

    if (not defined $args->{date_start} or $args->{date_start} !~ /^\d+$/) {
        return {
            error => {
                code    => 'InvalidDateStart',
                message => "Date expiry [_1] invalid",
                params  => [$args->{date_start}],
            }};
    }

    if (not defined $args->{date_expiry} or $args->{date_expiry} !~ /^\d+$/) {
        return {
            error => {
                code    => 'InvalidDateExpiry',
                message => "Date expiry [_1] invalid",
                params  => [$args->{date_expiry}],
            }};
    }

    if (not defined $args->{contract_category} or $args->{contract_category} !~ /^[a-z]+$/i) {
        return {
            error => {
                code    => 'InvalidContractCategory',
                message => "Contract category [_1] invalid",
                params  => [$args->{contract_category}],
            }};
    }

    if (not defined $args->{payout} or $args->{payout} <= 0) {
        return {
            error => {
                code    => 'InvalidPayout',
                message => "Payout [_1] invalid",
                params  => [$args->{payout}],
            }};
    }

    return;

}

sub get_channel_name {

    my $args = shift;
    my $id = join "::", 'PricingTable', $args->{symbol}, $args->{contract_category}, $args->{date_start}, $args->{date_expiry};

    return $id;
}

sub get_table {
    my $args = shift;
    my $id   = get_channel_name($args);

    my $redis_read = BOM::System::RedisReplicated::redis_read();
    return $redis_read->get($id);
}

sub update_table {
    my $args  = shift;
    my $table = shift;

    my %prices_table;
    foreach my $barrier (keys %$table) {
        foreach my $bet_type (keys %{$table->{$barrier}}) {
            my $params = $table->{$barrier}->{$bet_type};
            my $ask_price;
            my $default_price = $args->{payout};
            if (%$params) {
                $ask_price = BOM::RPC::v3::Contract::calculate_ask_price({
                    theo_probability      => $params->{theo_probability},
                    base_commission       => $params->{base_commission},
                    probability_threshold => $params->{probability_threshold},
                    amount                => $args->{payout},
                });
                $ask_price = roundnear(1, $ask_price);
                my $error = BOM::RPC::v3::Contract::validate_price({
                        ask_price         => $ask_price,
                        payout            => $args->{payout},
                        minimum_ask_price => $params->{minimum_stake},
                        maximum_payout    => $params->{maximum_payout}});
                $ask_price = $error ? $default_price : $ask_price;
            } else {
                $ask_price = $default_price;
            }

            $prices_table{$barrier} = {} if !defined $prices_table{$barrier};
            $prices_table{$barrier}->{$bet_type} = $ask_price;
        }
    }

    return \%prices_table;
}

1;
