package BOM::RPC::v3::Trading;

use strict;
use warnings;

no indirect;

use Future;

use BOM::RPC::Registry '-dsl';

requires_auth('trading', 'wallet');

=head2 trading_accounts

Placeholder for future documentation

=cut

async_rpc trading_platform_accounts => sub {
    my $params = shift;
    #TODO Add logic for returning list of trading accounts
    return Future->done([{
                account_id            => "DX10101",
                account_type          => "demo",
                balance               => 0,
                country               => 'my',
                currency              => 'USD',
                display_balance       => '0.00',
                email                 => $params->{client}->user->email,
                landing_company_short => "svg",
                login                 => '10101',
                market_type           => 'gaming',
                name                  => $params->{client}->full_name,
                platform              => 'dxtrader',
            },
        ]);
};

=head2 trading_new_account

Placeholder for future documentation

=cut

async_rpc trading_platform_new_account => sub {
    my $params = shift;
    #TODO Add logic for returning list of trading accounts
    return Future->done({
        account_id            => "DX10101",                                  # uniq identifyer of client account
        account_type          => "demo",
        balance               => 0,
        country               => $params->{args}{country} // 'my',
        currency              => 'USD',
        display_balance       => '0.00',
        email                 => $params->{client}->user->email,
        landing_company_short => "svg",
        login                 => '10101',                                    # Client login which will be used by client to log in
        market_type           => $params->{args}{market_type} // 'gaming',
        name                  => $params->{args}{name},
        platform              => 'dxtrader',
        $params->{args}{sub_account_type} ? (sub_account_type => $params->{args}{sub_account_type}) : (),
    });
};

=head2 trading_deposit

Placeholder for future documentation

=cut

async_rpc trading_platform_deposit => sub {
    my $params = shift;
    #TODO Add logic for returning list of trading accounts
    return Future->done({binary_transaction_id => 123});
};

=head2 trading_withdrawal

Placeholder for future documentation

=cut

async_rpc trading_platform_withdrawal => sub {
    my $params = shift;
    #TODO Add logic for returning list of trading accounts
    return Future->done({binary_transaction_id => 123});
};

1;
