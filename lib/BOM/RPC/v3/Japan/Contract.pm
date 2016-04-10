package BOM::RPC::v3::Japan::Contract;

use strict;
use warnings;

use BOM::Market::UnderlyingDB;
use BOM::RPC::v3::Utility;
use BOM::Platform::Context qw(localize);
use BOM::System::RedisReplicated;

sub validate_table_props {

    my $args = shift;

    if (ref $args ne 'HASH') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'WrongPricingTableargs',
                message_to_client => BOM::Platform::Context::localize("Wrong pricing table arguments")});
    }

    my %symbols = map { $_ => 1 } BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market    => 'forex',
        submarket => 'major_pairs'
    );

    # Japan has only Forex/Major-pairs contracts
    if (not defined $args->{symbol} or not $symbols{$args->{symbol}}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidSymbol',
                message_to_client => BOM::Platform::Context::localize("Symbol [_1] invalid", $args->{symbol})});
    }

    if (not defined $args->{date_expiry} or $args->{date_expiry} !~ /^\d+$/) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidDateExpiry',
                message_to_client => BOM::Platform::Context::localize("Date expiry [_1] invalid", $args->{date_expiry})});
    }

    if (not defined $args->{contract_category} or $args->{contract_category} !~ /^[a-z]+$/i) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidContractCategory',
                message_to_client => BOM::Platform::Context::localize("Contract category [_1] invalid", $args->{contract_category})});
    }

    return;

}

sub get_channel_name {

    my $args = shift;
    my $id = join "::", 'PricingTable', $args->{symbol}, $args->{contract_category}, $args->{date_expiry};

    return $id;
}

sub get_table {
    my $args = shift;
    my $id   = get_channel_name($args);

    my $redis_read = BOM::System::RedisReplicated::redis_read();
    return $redis_read->get($id);
}

1;
