package BOM::RPC::v3::CopyTrading;

use strict;
use warnings;

use BOM::Database::ClientDB;
use BOM::Platform::Context qw (localize);
use BOM::Platform::Copier;
use Client::Account;

use LandingCompany::Offerings;
use List::Util qw(first);

use Try::Tiny;

=head copy_start

Subscribe to trader operations

Example:

{
 args => {
   copy_start => 'NvervEV35353', #trader token, required
   min_trade_stake => 10,
   max_trade_stake => 100,
   trade_types     => ['CALL', 'PUT' ],
   assets          => ['R_50'],
 },
 client => $client, # blessed object of client, required
}

=cut

sub copy_start {
    my $params = shift;
    my $args   = $params->{args};

    for my $stake_limit (qw/max_trade_stake min_trade_stake/) {
        if ($args->{$stake_limit} && $args->{$stake_limit} < 0) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'InvalidStakeLimit',
                    message_to_client => localize('Option [_1] value must be zero or positive number.', $stake_limit)});
        }
    }
    if ($args->{max_trade_stake} && $args->{min_trade_stake} && $args->{min_trade_stake} > $args->{max_trade_stake}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidStakeLimit',
                message_to_client => localize('Min trade stake should be lower than max trade stake.')});
    }

    my $trader_token  = $args->{copy_start};
    my $token_details = BOM::RPC::v3::Utility::get_token_details($trader_token);
    my $trader        = try { Client::Account->new({loginid => $token_details->{loginid}}) };
    unless ($token_details && $trader) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidToken',
                message_to_client => localize('Invalid token')});
    }
    unless (grep { $_ eq 'read' } @{$token_details->{scopes}}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'PermissionDenied',
                message_to_client => localize('Permission denied, requires read scope.')});
    }
    unless ($trader->allow_copiers) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'CopyTradingNotAllowed',
                message_to_client => localize('Trader does not allow copy trading.')});
    }

    my $client = $params->{client};

    if ($client->broker_code ne 'CR') {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidAccount',
                message_to_client => localize('Copy trading is only available with real money accounts.')});
    }
    if ($client->allow_copiers) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'CopyTradingNotAllowed',
                message_to_client => localize('Traders are not allowed to copy trades.')});
    }

    my @trade_types = ref($args->{trade_types}) eq 'ARRAY' ? @{$args->{trade_types}} : $args->{trade_types};
    my $contract_types = LandingCompany::Offerings::get_all_contract_types();
    for my $type (grep { $_ } @trade_types) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidTradeType',
                message_to_client => localize('Invalid trade type: [_1].', $type)}) unless exists $contract_types->{$type};
    }

    my @assets = ref($args->{assets}) eq 'ARRAY' ? @{$args->{assets}} : $args->{assets};
    for my $symbol (grep { $_ } @assets) {
        my $response = BOM::RPC::v3::Contract::validate_underlying($symbol);
        if ($response and exists $response->{error}) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => $response->{error}->{code},
                    message_to_client => BOM::Platform::Context::localize($response->{error}->{message}, $symbol)});
        }
    }

    BOM::Platform::Copier->update_or_create({
        trader_id => $trader->loginid,
        copier_id => $client->loginid,
        broker    => $client->broker_code,
        %$args,
    });

    return {status => 1};
}

sub copy_stop {
    my $params = shift;
    my $args   = $params->{args};

    my $client = $params->{client};

    my $trader_token  = $args->{copy_stop};
    my $token_details = BOM::RPC::v3::Utility::get_token_details($trader_token);
    my $trader        = try { Client::Account->new({loginid => $token_details->{loginid}}) };
    unless ($token_details && $trader) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidToken',
                message_to_client => localize('Invalid token')});
    }

    BOM::Database::AutoGenerated::Rose::Copier::Manager->delete_copiers(
        db => BOM::Database::ClientDB->new({
                broker_code => $client->broker_code,
                operation   => 'write',
            }
            )->db,
        where => [
            trader_id => $trader->loginid,
            copier_id => $client->loginid,
        ],
    );

    return {status => 1};
}

1;

__END__
