package BOM::RPC::v3::CopyTrading;

use strict;
use warnings;

use Try::Tiny;
use Data::Dumper;

use BOM::Platform::Client;
use BOM::Database::ClientDB;
use BOM::Platform::Context qw (localize);
use BOM::Platform::Copiers;

use LandingCompany::Offerings;

sub copy_start {
    my $params = shift;
    my $args   = $params->{args};

    my $trader_token  = $args->{copy_start};
    my $token_details = BOM::RPC::v3::Utility::get_token_details($trader_token);
    my $trader = try { BOM::Platform::Client->new({loginid => $token_details->{loginid}}) };
    unless ($token_details && $trader) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidToken',
                message_to_client => localize('Invalid token')});
    }
    unless ($trader->allow_copiers) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'CopyTradingNotAllowed',
                message_to_client => localize('Trader does not allow copy trading.')});
    }

    my $client = $params->{client};

    if ($client->broker_code ne 'CR') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'IvalidAccount',
                message_to_client => localize('Copy trading allows for real money account only.')});
    }

    my @trade_types = ref($args->{trade_types}) eq 'ARRAY' ? @{$args->{trade_types}} : $args->{trade_types};
    my $contract_types = LandingCompany::Offerings::get_all_contract_types();
    for my $type (@trade_types) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'IvalidTradeType',
                message_to_client => localize('[_1]', $type)}) unless exists $contract_types->{$type};
    }

    BOM::Platform::Copiers->update_or_create({
        trader_id => $trader->loginid,
        copier_id => $client->loginid,
        broker => $client->broker_code,
        %$args,
    });

    return {status => 1};
}

sub copy_stop {
    my $params = shift;
    my $args   = $params->{args};

    my $trader_id = uc $params->{trader_id};
    my $trader = try { BOM::Platform::Client->new({loginid => $trader_id}) };
    unless ($trader) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'WrongLoginID',
                message_to_client => localize('Login ID ([_1]) does not exist.', $trader_id)});
    }

    # TODO check that current client copies the trader

    return {status => 1};
}

1;

__END__
