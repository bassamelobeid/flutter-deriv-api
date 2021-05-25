package BOM::RPC::v3::Trading;

use strict;
use warnings;
no indirect;

use Future;
use Log::Any qw($log);
use Syntax::Keyword::Try;
use BOM::TradingPlatform;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Email qw (send_email);
use BOM::Platform::Event::Emitter;
use BOM::Platform::Token;
use BOM::RPC::Registry '-dsl';
use BOM::RPC::v3::Utility;
use BOM::RPC::v3::MT5::Errors;
use BOM::RPC::v3::MT5::Account;
use BOM::User;
use BOM::User::Password;
use List::Util qw(first);

requires_auth('trading', 'wallet');

my $mt5_errors = BOM::RPC::v3::MT5::Errors->new();

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
        PlatformTransferRealParams      => localize('A Deriv account ID and amount must be provided for real accounts.'),
        PasswordRequired                => localize('A new password is required'),
        PasswordError                   => localize('Provided password is incorrect.'),
        PasswordReset                   => localize('Please reset your password to continue.'),
        OldPasswordRequired             => localize('Old password cannot be empty.'),
        NoOldPassword                   => localize('Old password cannot be provided until a trading password has been set.'),
        OldPasswordError                => localize("You've used this password before. Please create a different one."),
        MT5InvalidAccount               => localize('An invalid MT5 account ID was provided.'),
        MT5Suspended                    => localize('MT5 account management is currently suspended.'),
        PlatformPasswordChangeSuspended =>
            localize("We're unable to change your trading password due to scheduled maintenance. Please try again later."),
        CurrencyShouldMatch     => localize('Currency provided is different from account currency.'),
        RealAccountMissing      => localize('You are on a virtual account. To open a [_1] account, please upgrade to a real account.'),
        FinancialAccountMissing =>
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
        my $error = BOM::RPC::v3::Utility::set_trading_password_new_account($params->{client}, $params->{args}{password});
        die +{error_code => $error} if $error;
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
    my $params      = shift;
    my $client      = $params->{client};
    my $brand       = request()->brand;
    my $contact_url = $brand->contact_url({
            source   => $params->{source},
            language => $params->{language}});

    my $user = $client->user;

    try {
        my $new_password = $params->{args}{new_password} or die +{error_code => 'PasswordRequired'};
        my $old_password = $params->{args}{old_password};

        if (my $current_password = $user->trading_password) {
            die +{error_code => 'OldPasswordRequired'} unless $old_password;

            my $error = BOM::RPC::v3::Utility::validate_password_with_attempts($old_password, $current_password, $client->loginid);
            die +{error_code => $error} if $error;

            $error = BOM::RPC::v3::Utility::check_password({
                email        => $client->email,
                new_password => $new_password,
                old_password => $old_password,
                user_pass    => $current_password,
            });
            die $error->{error} if $error;
        } else {
            die +{error_code => 'NoOldPassword'} if $old_password;

            my $error = BOM::RPC::v3::Utility::check_password({
                email        => $client->email,
                new_password => $new_password,
            });
            die $error->{error} if $error;
        }

        change_platform_passwords($client, $new_password, $contact_url, $brand)->get;
        $user->update_trading_password($new_password);

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

async_rpc trading_platform_password_reset => auth => [],
    sub {
    my $params      = shift;
    my $brand       = request()->brand;
    my $contact_url = $brand->contact_url({
            source   => $params->{source},
            language => $params->{language}});

    try {
        my $password = delete $params->{args}{new_password};
        die +{error_code => 'PasswordRequired'} unless $password;

        my $verification_code = delete $params->{args}{verification_code};
        my $email             = lc(BOM::Platform::Token->new({token => $verification_code})->email // '');

        my $error = BOM::RPC::v3::Utility::is_verification_token_valid($verification_code, $email, 'trading_platform_password_reset')->{error};
        die $error if $error;

        $error = BOM::RPC::v3::Utility::check_password({
            email        => $email,
            new_password => $password
        });
        die $error->{error} if $error;

        my $user = BOM::User->new(email => $email);
        change_platform_passwords($user->get_default_client(), $password, $contact_url, $brand)->get;

        $user->update_trading_password($password);

        return Future->done(1);
    } catch ($e) {
        return Future->fail(handle_error($e));
    }
    };

=head2 trading_platform_investor_password_change

Changes the Trading Platform investor password of the account.

Returns a L<Future> which resolves to C<1> on success.

=cut

async_rpc trading_platform_investor_password_change => sub {
    my $params = shift;
    my $client = $params->{client};

    try {
        my $account_id   = $params->{args}{account_id};
        my $new_password = $params->{args}{new_password};
        my $old_password = $params->{args}{old_password};

        die +{error_code => 'PasswordRequired'} unless $new_password;
        die +{error_code => 'OldPasswordError'} if $old_password and ($new_password eq $old_password);

        my $error = BOM::RPC::v3::Utility::validate_mt5_password({
            email           => $client->email,
            invest_password => $new_password
        });
        die +{code => $error} if $error;

        my $platform = BOM::TradingPlatform->new(
            platform => $params->{args}{platform},
            client   => $client
        );

        $platform->change_investor_password(
            old_password => $old_password,
            new_password => $new_password,
            account_id   => $account_id
        )->get;

        BOM::Platform::Event::Emitter::emit(
            'mt5_password_changed',
            {
                loginid     => $client->loginid,
                mt5_loginid => $account_id
            });

        return Future->done(1);
    } catch ($e) {
        Future->fail(handle_error($e));
    }
};

=head2 trading_platform_investor_password_reset

Reset the Trading Platform investor password of the account.

Returns a L<Future> which resolves to C<1> on success.

=cut

async_rpc trading_platform_investor_password_reset => auth => [],
    => sub {
    my $params = shift;

    try {
        my $account_id = $params->{args}{account_id};
        my $password   = $params->{args}{new_password};
        die +{error_code => 'PasswordRequired'} unless $password;

        my $verification_code = delete $params->{args}{verification_code};
        my $email             = lc(BOM::Platform::Token->new({token => $verification_code})->email // '');

        my $error =
            BOM::RPC::v3::Utility::is_verification_token_valid($verification_code, $email, 'trading_platform_investor_password_reset')->{error};
        die $error if $error;

        my $user   = BOM::User->new(email => $email);
        my $client = $user->get_default_client();

        $error = BOM::RPC::v3::Utility::validate_mt5_password({
            email           => $email,
            invest_password => $password
        });
        die +{code => $error} if $error;

        my $platform = BOM::TradingPlatform->new(
            platform => $params->{args}{platform},
            client   => $client
        );

        $platform->change_investor_password(
            new_password => $password,
            account_id   => $account_id
        )->get;

        my $brand        = request()->brand;
        my $contact_url  = $brand->contact_url($params);
        my $account_info = $platform->get_account_info($account_id)->get;

        send_email({
                from    => Brands->new(name => $brand)->emails('support'),
                to      => $email,
                subject => $brand->name eq 'deriv'
                ? localize('Your new DMT5 account investor password')
                : localize('Your MT5 investor password has been reset.'),
                template_name => 'mt5_password_reset_notification',
                template_args => {
                    name                 => $client->first_name,
                    title                => localize("You've got a new password"),
                    loginid              => $account_id,
                    email                => $email,
                    contact_url          => $contact_url,
                    is_investor_password => 1
                },
                use_event             => 1,
                use_email_template    => 1,
                email_content_is_html => 1,
                template_loginid      => ucfirst $account_info->{account_type} . ' ' . $account_id =~ s/${\BOM::User->MT5_REGEX}//r,
            });

        return Future->done(1);
    } catch ($e) {
        Future->fail(handle_error($e));
    }
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
            if (my $message = $e->{message_to_client} // $ERROR_MAP{$code} // BOM::RPC::v3::Utility::error_map()->{$code}) {
                return BOM::RPC::v3::Utility::create_error({
                    code              => $code,
                    message_to_client => localize($message, ($e->{message_params} // [])->@*),
                    $e->{details} ? (details => $e->{details}) : (),
                });
            } elsif (my $formatted_errors = $mt5_errors->format_error($e->{code}, $e)->{error}) {
                return BOM::RPC::v3::Utility::create_error($formatted_errors);
            }
        }
    }

    $log->errorf('Trading platform unexpected error: %s', $e);

    return BOM::RPC::v3::Utility::create_error({
        code              => 'TradingPlatformError',
        message_to_client => localize('Sorry, an error occurred. Please try again later.'),
    });
}

=head2 change_platform_passwords

Changes trading password on all MT5 & DXtrader accounts.

=over 4

=item * C<client> (required). a user C<BOM::User::Client> instance.

=item * C<password> (required). the new password.

=item * C<contact_url> (required). the Brand contact_url to pass to email template.

=item * C<brand> (required). the Brand name to pass to email template.

=back

Returns Future on success, dies on error.

=cut

sub change_platform_passwords {
    my ($client, $password, $contact_url, $brand) = @_;

    my $mt5 = BOM::TradingPlatform->new(
        platform => 'mt5',
        client   => $client
    );
    my $dxtrade = BOM::TradingPlatform->new(
        platform => 'dxtrade',
        client   => $client
    );

    return Future->needs_all($mt5->change_password(password => $password), Future->done($dxtrade->change_password(password => $password)))->else(
        sub {
            my @results = @_;

            my ($failed_logins, $logins);
            push @{$_->is_failed ? $failed_logins : $logins}, $_->is_failed ? $_->failure->{login} : $_->result->{login} for @results;

            if ($failed_logins) {
                my $failed_logins_str = join(', ', @{$failed_logins});
                my $message_to_client =
                    scalar(@{$failed_logins}) > 1
                    ? localize(
                    "Due to a network issue, we're unable to update your trading password for the following accounts: [_1]. Please wait for a few minutes before attempting to change your trading password for the above accounts.",
                    $failed_logins_str
                    )
                    : localize(
                    "Due to a network issue, we're unable to update your trading password for the following account: [_1]. Please wait for a few minutes before attempting to change your trading password for the above account.",
                    $failed_logins_str
                    );

                send_email({
                        to            => $client->email,
                        subject       => localize('Unsuccessful trading password change'),
                        template_name => 'reset_password_confirm',
                        template_args => {
                            email                             => $client->email,
                            name                              => $client->first_name,
                            title                             => localize("There was an issue with changing your trading password"),
                            contact_url                       => $contact_url,
                            is_trading_password_change_failed => 1,
                            logins                            => $logins,
                            failed_logins                     => $failed_logins
                        },
                        use_email_template => 1,
                        template_loginid   => $client->loginid,
                        use_event          => 1,
                    });

                die +{
                    code              => 'PlatformPasswordChangeError',
                    message_to_client => $message_to_client,
                };
            }
        }
    )->then(
        sub {
            my @results = @_;
            my @logins  = map { $_->{login} } grep { ref $_ eq 'HASH' } @results;

            # TODO: replace send_email with bom-events
            send_email({
                    to            => $client->email,
                    subject       => localize('Your [_1] trading password has been set', ucfirst($brand->name)),
                    template_name => 'reset_password_confirm',
                    template_args => {
                        email               => $client->email,
                        name                => $client->first_name,
                        title               => localize("You've got a new trading password"),
                        contact_url         => $contact_url,
                        is_trading_password => 1,
                        logins              => \@logins,
                    },
                    use_email_template => 1,
                    template_loginid   => $client->loginid,
                    use_event          => 1,
                });
        });
}

1;
