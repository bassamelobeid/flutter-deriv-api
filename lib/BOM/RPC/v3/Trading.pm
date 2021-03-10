package BOM::RPC::v3::Trading;

use strict;
use warnings;
no indirect;

use Future;
use Syntax::Keyword::Try;
use BOM::TradingPlatform;
use BOM::Platform::Context qw (localize);
use BOM::RPC::Registry '-dsl';

requires_auth('trading', 'wallet');

my %ERROR_MAP = do {
    # Show localize to `make i18n` here, so strings are picked up for translation.
    # Call localize again on the hash value to do the translation at runtime.
    ## no critic(TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'redefine';
    local *localize = sub { die 'you probably wanted an arrayref for this localize() call' if @_ > 1; shift };
    (
        DXtradeNoCurrency      => localize('Please provide a currency for the DXtrade account.'),
        ExistingDXtradeAccount => localize('You already have DXtrade account of this type (account ID [_1]).'),
    );
};

=head2 trading_platform_accounts

Return list of accounts.

=cut

rpc trading_platform_accounts => sub {
    my $params = shift;
    try {
        return get_platform($params)->get_accounts($params->{args}->%*);
    } catch ($e) {
        handle_error($e);
    }
};

=head2 trading_platform_new_account

Create new account.

=cut

rpc trading_platform_new_account => sub {
    my $params = shift;

    try {
        return get_platform($params)->new_account($params->{args}->%*);
    } catch ($e) {
        handle_error($e);
    }
};

=head2 trading_platform_deposit

Placeholder for future documentation

=cut

async_rpc trading_platform_deposit => sub {
    my $params = shift;
    #TODO Add logic for returning list of trading accounts
    return Future->done({binary_transaction_id => 123});
};

=head2 trading_platform_withdrawal

Placeholder for future documentation

=cut

async_rpc trading_platform_withdrawal => sub {
    my $params = shift;
    #TODO Add logic for returning list of trading accounts
    return Future->done({binary_transaction_id => 123});
};

=head2 get_platform

Creates the platform object from $params.

=cut

sub get_platform {
    my $params = shift;

    return BOM::TradingPlatform->new(
        platform => $params->{args}{platform},
        client   => $params->{client});
}

=head2 handle_error

Common error handler.

=cut

sub handle_error {
    my $e = shift;

    if (ref $e eq 'HASH' and $e->{error_code} and $ERROR_MAP{$e->{error_code}}) {
        return BOM::RPC::v3::Utility::create_error({
            code              => $e->{error_code},
            message_to_client => localize($ERROR_MAP{$e->{error_code}}, ($e->{message_params} // [])->@*),
        });
    } else {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'TradingPlatformError',
            message_to_client => localize('Sorry, an error occurred. Please try again later.'),
        });
    }

}

1;
