package BOM::RPC::v3::Trading;

use strict;
use warnings;
no indirect;

use Future;
use Log::Any qw($log);
use Syntax::Keyword::Try;
use BOM::TradingPlatform;
use BOM::Platform::Context qw (localize);
use BOM::RPC::Registry '-dsl';
use List::Util qw(first);

requires_auth('trading', 'wallet');

my %ERROR_MAP = do {
    # Show localize to `make i18n` here, so strings are picked up for translation.
    # Call localize again on the hash value to do the translation at runtime.
    ## no critic(TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'redefine';
    local *localize = sub { die 'you probably wanted an arrayref for this localize() call' if @_ > 1; shift };
    (
        DXSuspended           => localize('Deriv X account management is currently suspended.'),
        DXtradeNoCurrency     => localize('Please provide a currency for the Deriv X account.'),
        DXExistingAccount     => localize('You already have Deriv X account of this type (account ID [_1]).'),
        DXInvalidAccount      => localize('An invalid Deriv X account ID was provided.'),
        DXDepositFailed       => localize('The required funds could not be withdrawn from your Deriv account. Pleaese try a different account.'),
        DXDepositIncomplete   => localize('The deposit to your Deriv X account did not complete. Please contact our Customer Support team.'),
        DXInsufficientBalance => localize('Your Deriv X account balance is insufficient for this withdrawal.'),
        DXWithdrawalFailed    =>
            localize('The required funds could not be withdrawn from your Deriv X account. Pleaese try later or use a different account.'),
        DXWithdrawalIncomplete  => localize('The credit to your Deriv account did not complete. Please contact our Customer Support team.'),
        DXTransferCompleteError => localize('The transfer completed successfully, but an error occured when getting account details.'),
        DXDemoTopupBalance      =>
            localize('We cannot complete your request. You can only top up your Deriv X demo account when the balance falls below [_1] [_2].'),
        DXDemoTopFailed                        => localize('Your Deriv X demo account could not be topped up at this time. Please try later.'),
        PlatformTransferTemporarilyUnavailable => localize('Transfers between these accounts are temporarily unavailable. Please try later.'),
        PlatformTransferError                  => localize('The transfer could not be completed: [_1]'),
        PlatformTransferSuspended              => localize('Transfers are suspended for system maintenance. Please try later.'),
        PlatformTransferBlocked                => localize('Transfers have been blocked on this account.'),
        PlatformTransferCurrencySuspended      => localize('[_1] currency transfers are suspended.'),
        PlatformTransferNocurrency             => localize('Please select your account currency first.'),
        PlatformTransferNoVirtual              => localize('This feature is not available for virtual accounts.'),
        PlatformTransferWalletOnly             => localize('This feature is only available for wallet accounts.'),
        PlatformTransferDemoOnly               => localize('Both accounts must be demo accounts.'),
        PlatformTransferRealOnly               => localize('Both accounts must be real accounts.'),
        PlatformTransferAccountInvalid         => localize('The provided Deriv account ID is not valid.'),
        PlatformTransferOauthTokenRequired     =>
            localize('This request must be made using a connection authorized by the Deriv account involved in the transfer.'),
        PlatformTransferRealParams => localize('A Deriv account ID and amount must be provided for real accounts.'),
        PasswordRequired           => localize('A new password is required'),
        CurrencyShouldMatch        => localize('Currency provided is different from account currency.'),
        RealAccountMissing         => localize('You are on a virtual account. To open a [_1] account, please upgrade to a real account.'),
        FinancialAccountMissing    =>
            localize('Your existing account does not allow [_1] trading. To open a [_1] account, please upgrade to a financial account.'),
        GamingAccountMissing =>
            localize('Your existing account does not allow [_1] trading. To open a [_1] account, please upgrade to a gaming account.'),
        AccountShouldBeReal              => localize('Only real accounts are allowed to open [_1] real accounts'),
        NoAgeVerification                => localize("You haven't verified your age. Please contact us for more information."),
        FinancialAssessmentMandatory     => localize('Please complete your financial assessment.'),
        TINDetailsMandatory              => localize('We require your tax information for regulatory purposes. Please fill in your tax information.'),
        TradingAccountNotAllowed         => localize('This trading platform account is not available in your country yet.'),
        TradingAccountCurrencyNotAllowed => localize('This currency is not available.'),
        CurrencyRequired                 => localize('Please provide valid currency.'),
        MaximumTransfers                 => localize('You can only perform up to [_1] transfers a day. Please try again tomorrow.'),
        InvalidMinAmount                 => localize('The minimum amount for transfers is [_1] [_2]. Please adjust your amount.'),
        InvalidMaxAmount                 => localize('The maximum amount for deposits is [_1] [_2]. Please adjust your amount.'),
        CurrencyTypeNotAllowed           => localize('This currency is temporarily suspended. Please select another currency to proceed.'),
    );
};

=head2 trading_platform_new_account

Create new account.

=cut

rpc trading_platform_new_account => sub {
    my $params = shift;

    try {
        my $platform = BOM::TradingPlatform->new(
            platform => $params->{args}{platform},
            client   => $params->{client});
        return $platform->new_account($params->{args}->%*);
    } catch ($e) {
        handle_error($e);
    }
};

=head2 trading_platform_accounts

Return list of accounts.

=cut

rpc trading_platform_accounts => sub {
    my $params = shift;
    try {
        my $platform = BOM::TradingPlatform->new(
            platform => $params->{args}{platform},
            client   => $params->{client});
        return $platform->get_accounts($params->{args}->%*);
    } catch ($e) {
        handle_error($e);
    }
};

=head2 trading_platform_deposit

Transfer from deriv to platform account.

=cut

rpc trading_platform_deposit => sub {
    my $deposit = deposit(shift);
    return $deposit if $deposit->{error};
    return $deposit->{transaction_id} ? {transaction_id => $deposit->{transaction_id}} : {status => 1};
};

=head2 trading_platform_withdrawal

Transfer from platform to deriv account.

=cut

rpc trading_platform_withdrawal => sub {
    my $withdrawal = withdrawal(shift);
    return $withdrawal if $withdrawal->{error};
    return {transaction_id => $withdrawal->{transaction_id}};
};

=head2 trading_platform_password_change

Changes the Trading Platform password of the account.

Must provide old password for verification.

Returns a L<Future> which resolves to C<1> on success.

=cut

async_rpc trading_platform_password_change => sub {
    my $params = shift;

    try {
        my $password = delete $params->{args}{new_password};
        #die +{error_code => 'PasswordRequired'} unless $password;

        # TODO: old password check

        # TODO: remianing trading platforms implementation

        # DevExperts Implementation

        my $dxtrade = BOM::TradingPlatform->new(
            platform => 'dxtrade',
            client   => $params->{client});

        $dxtrade->change_password(password => $password);

        return Future->done(1);
    } catch ($e) {
        return Future->fail(handle_error($e));
    }
};

=head2 trading_platform_password_reset

Changes the password of the specified Trading Platform account.

Must provide verification code to validate the request.

Returns a L<Future> which resolves to C<1> on success.

=cut

async_rpc trading_platform_password_reset => sub {
    my $params = shift;
    # TODO implement it
    return Future->done(1);
};

=head2 deposit

Platform deposit implementation.

=cut

sub deposit {
    my $params = shift;

    # Note `transfer_between_accounts` may pass `currency` param, which we should validate.
    # The validation will always pass for `transfer_between_deposit` and `transfer_between_withdrawal`
    # as they don't pass the `currency` param, we use the account currency instead which should be valid.

    my ($from_account, $to_account, $amount, $currency) = $params->{args}->@{qw/from_account to_account amount currency/};
    my $is_demo = $to_account =~ /^DXD/;

    try {
        die +{error_code => 'PlatformTransferRealParams'} unless $is_demo or ($from_account and $amount);

        my $client = $is_demo ? $params->{client} : get_transfer_client($params, $from_account);

        my $platform = BOM::TradingPlatform->new(
            platform => $params->{args}{platform},
            client   => $client
        );

        return $platform->deposit(
            to_account => $to_account,
            amount     => $amount,
            currency   => $currency,
        );

    } catch ($e) {
        handle_error($e);
    }
}

=head2 withdrawal

Platform withdrawal implementation.

=cut

sub withdrawal {
    my $params = shift;

    my ($from_account, $to_account, $amount, $currency) = $params->{args}->@{qw/from_account to_account amount currency/};
    try {
        my $client = get_transfer_client($params, $to_account);

        my $platform = BOM::TradingPlatform->new(
            platform => $params->{args}{platform},
            client   => $client
        );

        return $platform->withdraw(
            from_account => $from_account,
            amount       => $amount,
            currency     => $currency,
        );

    } catch ($e) {
        handle_error($e);
    }
}

=head2 get_transfer_client

Validates and returns client instance for deposit and withdrawal.

=cut

sub get_transfer_client {
    my ($params, $loginid) = @_;

    my $client = $params->{client};
    return $client if $client->loginid eq $loginid;

    die +{error_code => 'PlatformTransferOauthTokenRequired'} unless ($params->{token_type} // '') eq 'oauth_token';

    my @siblings = $client->user->clients(include_disabled => 0);
    my $result   = first { $_->loginid eq $loginid } @siblings;
    die +{error_code => 'PlatformTransferAccountInvalid'} unless $result;
    return $result;
}

=head2 handle_error

Common error handler.

=cut

sub handle_error {
    my $e = shift;

    if (ref $e eq 'HASH') {
        if (my $code = $e->{error_code} // $e->{code}) {
            if (my $message = $ERROR_MAP{$code} // BOM::RPC::v3::Utility::error_map()->{$code}) {
                return BOM::RPC::v3::Utility::create_error({
                    code              => $code,
                    message_to_client => localize($message, ($e->{message_params} // [])->@*),
                    $e->{details} ? (details => $e->{details}) : (),
                });
            }
        }
    }

    $log->errorf('Trading platform unexpected error: %s', $e);

    return BOM::RPC::v3::Utility::create_error({
        code              => 'TradingPlatformError',
        message_to_client => localize('Sorry, an error occurred. Please try again later.'),
    });
}

1;
