package BOM::RPC::v3::Japan::Contract;

use strict;
use warnings;

use BOM::Market::UnderlyingDB;

use constant PRICES => 'PricingTable';

sub validate_table_props {

    my $props = shift;

    if (ref $props ne 'HASH') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'WrongPricingTableProps',
                message_to_client => BOM::Platform::Context::localize("Wrong pricing table props")});
    }

    my %symbols = map { ($_, 1) } BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market    => 'forex',
        submarket => 'major_pairs'
    );

    # Japan has only Forex/Major-pairs contracts
    if (not defined $props->{symbol} or not $symbols{$props->{symbol}}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidSymbol',
                message_to_client => BOM::Platform::Context::localize("Symbol [_1] invalid", ($props->{symbol} || 'undefined'))});
    }

    if (not defined $props->{date_expiry} or $props->{date_expiry} !~ /^\d+$/ or $props->{date_expiry} < time) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidDateExpiry',
                message_to_client => BOM::Platform::Context::localize("Date expiry [_1] invalid", ($props->{date_expiry} || 'undefined'))});
    }

    if (not defined $props->{contract_category} or $props->{contract_category} !~ /^[a-z]+$/i) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidContractCategory',
                message_to_client => BOM::Platform::Context::localize("Contract category [_1] invalid", ($props->{contract_category} || 'undefined'))}
        );
    }

    return;

}

sub get_channel_name {

    my $args  = shift;
    my $props = $args->{props} || {};
    my $id    = join "::", PRICES, $props->{symbol}, $props->{contract_category}, $props->{date_expiry};

    return $id;
}

1;
