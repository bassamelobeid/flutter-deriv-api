package BOM::RPC::v3::CopyTrading;

use strict;
use warnings;

use BOM::Database::ClientDB;
use BOM::Platform::Context qw (localize);
use BOM::Platform::Copier;
use BOM::User::Client;

use BOM::RPC::Registry '-dsl';

use Finance::Contract::Category;
use Syntax::Keyword::Try;
use Log::Any qw($log);

requires_auth('trading');

rpc copy_start => sub {
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

    my $trader_token   = $args->{copy_start};
    my $token_instance = BOM::Platform::Token::API->new;
    my $token_details  = $token_instance->get_client_details_from_token($trader_token);
    my $trader;
    if ($token_details && $token_details->{loginid}) {
        try {
            $trader = BOM::User::Client->new({
                loginid      => $token_details->{loginid},
                db_operation => 'replica'
            });
        } catch ($e) {
            $log->warnf("Error when get client. more detail: %s", $e);
        };
    }
    unless ($token_details && $trader) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidToken',
                message_to_client => localize('Invalid token')});
    }
    unless (grep { $_ eq 'read' or $_ eq 'trading_information' } @{$token_details->{scopes}}) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'PermissionDenied',
                message_to_client => localize('Permission denied, requires read or [_1] scopes.', 'trading_information')});
    }
    unless ($trader->allow_copiers) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'CopyTradingNotAllowed',
                message_to_client => localize('Trader does not allow copy trading.')});
    }

    my $client = $params->{client};

    if ($client->allow_copiers) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'CopyTradingNotAllowed',
                message_to_client => localize('Traders are not allowed to copy trades.')});
    }
    if ($client->landing_company->short ne $trader->landing_company->short) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'CopyTradingNotAllowed',
                message_to_client => localize('Trader and copier must have the same landing company.')});
        # This is a business decision, not a technical limitation.
    }

    unless ($client->default_account
        && $trader->default_account
        && ($client->default_account->currency_code() eq $trader->default_account->currency_code()))
    {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'CopyTradingWrongCurrency',
            message_to_client => localize('Your account currency and trader currency must be same.'),
        });
    }

    my @trade_types    = ref($args->{trade_types}) eq 'ARRAY' ? @{$args->{trade_types}} : $args->{trade_types};
    my $contract_types = Finance::Contract::Category::get_all_contract_types();
    for my $type (grep { $_ } @trade_types) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidTradeType',
                message_to_client => localize('Invalid trade type: [_1].', $type)}) unless exists $contract_types->{$type};
    }

    my @assets = ref($args->{assets}) eq 'ARRAY' ? @{$args->{assets}} : $args->{assets};
    for my $symbol (grep { $_ } @assets) {
        my $response = BOM::RPC::v3::Contract::is_invalid_symbol($symbol);
        if ($response and exists $response->{error}) {
            return $response;
        }
    }

    BOM::Platform::Copier->update_or_create({
        trader_id    => $trader->loginid,
        copier_id    => $client->loginid,
        broker       => $client->broker_code,
        trader_token => $trader_token,
        %$args,
    });

    return {status => 1};
};

rpc copy_stop => sub {
    my $params = shift;
    my $args   = $params->{args};

    my $client = $params->{client};

    my $trader_token = $args->{copy_stop};

    my $trader_id;
    my $token_instance = BOM::Platform::Token::API->new;
    my $token_details  = $token_instance->get_client_details_from_token($trader_token);
    $trader_id = $token_details->{loginid} if ref $token_details eq 'HASH';

    unless ($trader_id) {
        my $copier = BOM::Database::AutoGenerated::Rose::Copier::Manager->get_copiers(
            db => BOM::Database::ClientDB->new({
                    broker_code => $client->broker_code,
                    operation   => 'replica',
                }
            )->db,
            query => [trader_token => $trader_token],
            limit => 1,
        );
        $trader_id = $copier->[0]->trader_id if @$copier;
    }

    unless ($trader_id) {
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
            trader_id => $trader_id,
            copier_id => $client->loginid,
        ],
    );

    return {status => 1};
};

rpc copytrading_list => sub {
    my $params = shift;

    my $current_client = $params->{client};

    my $copiers_data_mapper = BOM::Database::DataMapper::Copier->new({
        broker_code => $current_client->broker_code,
        operation   => 'replica'
    });

    my $copiers_tokens = $copiers_data_mapper->get_copiers_tokens_all({trader_id => $current_client->loginid});
    my @copiers        = map { {loginid => $_->[0]} } @$copiers_tokens;

    my $traders = [];
    unless (scalar @copiers) {
        $traders = $copiers_data_mapper->get_traders_all({copier_id => $current_client->loginid});
    }
    return {
        copiers => \@copiers,
        traders => $traders
    };
};

1;

__END__
