package BOM::RPC::v3::Trading;

use strict;
use warnings;
no indirect;

use Future;
use Log::Any qw($log);
use Syntax::Keyword::Try;
use List::Util qw(first none any);

use BOM::TradingPlatform;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Email   qw (send_email);
use BOM::Platform::Event::Emitter;
use BOM::Platform::Token;
use BOM::Platform::Utility;
use BOM::RPC::Registry '-dsl';
use BOM::RPC::v3::Utility;
use BOM::RPC::v3::MT5::Errors;
use BOM::RPC::v3::MT5::Account;
use BOM::User;
use BOM::User::Password;
use BOM::Product::Listing;
use BOM::Config;

requires_auth('trading', 'wallet');

my $mt5_errors = BOM::RPC::v3::MT5::Errors->new();

my %ERROR_MAP = do {
    # Show localize to `make i18n` here, so strings are picked up for translation.
    # Call localize again on the hash value to do the translation at runtime.
    # Check BOM::RPC::v3::Utility::error_map if you can't find an error code here.
    ## no critic(TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'redefine';
    local *localize = sub { die 'you probably wanted an arrayref for this localize() call' if @_ > 1; shift };
    (
        DXtradeNoCurrency     => localize('Please provide a currency for the Deriv X account.'),
        DXExistingAccount     => localize('You already have Deriv X account of this type (account ID [_1]).[_2]'),
        DXInvalidAccount      => localize('An invalid Deriv X account ID was provided.'),
        DXInvalidMarketType   => localize('An invalid Deriv X market type was provided for [_1] account creation'),
        DXDepositFailed       => localize('The required funds could not be withdrawn from your Deriv account. Please try a different account.'),
        DXDepositIncomplete   => localize('The deposit to your Deriv X account did not complete. Please contact our Customer Support team.'),
        DXInsufficientBalance => localize('Your Deriv X account balance is insufficient for this withdrawal.'),
        DXWithdrawalFailed    =>
            localize('The required funds could not be withdrawn from your Deriv X account. Please try later or use a different account.'),
        DXWithdrawalIncomplete  => localize('The credit to your Deriv account did not complete. Please contact our Customer Support team.'),
        DXTransferCompleteError => localize('The transfer completed successfully, but an error occured when getting account details.'),
        DXDemoTopupBalance      =>
            localize('We cannot complete your request. You can only top up your Deriv X demo account when the balance falls below [_1] [_2].'),
        DXDemoTopFailed                        => localize('Your Deriv X demo account could not be topped up at this time. Please try later.'),
        DXNewAccountFailed                     => localize('There was an error while creating your account. Please try again later.'),
        CTraderNotAllowed                      => localize('cTrader account or landing company is not available in your country yet.'),
        CTraderInvalidMarketType               => localize('An invalid cTrader market type was provided for account creation.'),
        CTraderInvalidAccountType              => localize('An invalid cTrader account type was provided for account creation.'),
        CTIDGetFailed                          => localize('Failed to retrieve new or existing CTID.'),
        CTraderExistingAccountGroupMissing     => localize('Existing cTrader accounts missing group data.'),
        CTraderAccountCreateFailed             => localize('There was an error creating cTrader account. Please try again later.'),
        CTraderAccountLinkFailed               => localize('There was an error linking created cTrader account. Please try again later.'),
        CTraderUnsupportedCountry              => localize('cTrader unsupported country code.'),
        CTraderInvalidGroup                    => localize('cTrader invalid group provided.'),
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
        PasswordError              => localize('That password is incorrect. Please try again.'),
        PasswordReset              => localize('Please reset your password to continue.'),
        OldPasswordRequired        => localize('Old password cannot be empty.'),
        NoOldPassword              => localize('Old password cannot be provided until a trading password has been set.'),
        OldPasswordError           => localize("You've used this password before. Please create a different one."),
        MT5InvalidAccount          => localize('An invalid MT5 account ID was provided.'),
        MT5Suspended               => localize('MT5 account management is currently suspended.'),
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
        MaximumAmountTransfers           => localize('The maximum amount of transfers is [_1] [_2] per day. Please try again tomorrow.'),
        InvalidMinAmount                 => localize('The minimum amount for transfers is [_1] [_2]. Please adjust your amount.'),
        InvalidMaxAmount                 => localize('The maximum amount for deposits is [_1] [_2]. Please adjust your amount.'),
        CurrencyTypeNotAllowed           => localize('This currency is temporarily suspended. Please select another currency to proceed.'),
        PlatformPasswordChangeSuspended => localize("We're unable to reset your trading password due to system maintenance. Please try again later."),
        DifferentLandingCompanies       => localize(
            "Transfers between EU and non-EU accounts aren't allowed. You can only transfer funds between accounts under the same regulator."),
        CTraderInvalidAccount   => localize('An invalid cTrader account ID was provided.'),
        CTraderDemoTopupBalance =>
            localize('We cannot complete your request. You can only top up your cTrader demo account when the balance falls below [_1] [_2].'),
        CTraderDemoTopFailed       => localize('Your cTrader demo account could not be topped up at this time. Please try later.'),
        CTraderDepositFailed       => localize('The required funds could not be deposited to your cTrader account. Please try a different account.'),
        CTraderDepositIncomplete   => localize('The deposit to your cTrader account did not complete. Please contact our Customer Support team.'),
        CTraderInsufficientBalance => localize('Your cTrader account balance is insufficient for this withdrawal.'),
        CTraderWithdrawalFailed    =>
            localize('The required funds could not be withdrawn from your cTrader account. Please try later or use a different account.'),
        CTraderWithdrawalIncomplete   => localize('The credit to your Deriv account did not complete. Please contact our Customer Support team.'),
        CTraderTransferCompleteError  => localize('The transfer completed successfully, but an error occured when getting account details.'),
        TradingPlatformInvalidAccount => localize("This [_1] account is not available for your account."),
        CTraderExistingAccountLimitExceeded =>
            localize('Maximum allowed cTrader [_1] accounts per client exceeded. You can have up to [_2] cTrader accounts.'),
        CTraderAccountCreationInProgress => localize('Your account creation is still in progress. Please wait for completion.'),
    );
};

=head2 trading_platform_product_listing

Returns product offerings for the given input. If no input is provided, it returns product listing for all platform and countries.

=over 4

=item * platform - a string to represent trading platform. (E.g. binary_bot)

=item * residence - a 2-letter country code.

=back

=cut

rpc trading_platform_product_listing => auth => [],
    sub {
    my $params = shift;

    my $client     = $params->{client};
    my $args       = $params->{args};
    my $brand_name = request()->brand->name;

    my $resp;
    try {
        my $country_code = $args->{country_code} ? $args->{country_code} : $client ? $client->residence : undef;
        $resp = BOM::Product::Listing->new(brand_name => $brand_name)->by_country($args->{country_code}, $args->{app_id});
    } catch ($e) {
        handle_error($e);
    }

    return $resp;
    };

=head2 trading_platform_asset_listing

Returns asset listing for trading platform

=over 4

=item * platform - a string to represent trading platform. (E.g. binary_bot)

=back

=cut

rpc trading_platform_asset_listing => auth => [],
    sub {
    my $params = shift;

    my $client = $params->{client};
    my $args   = $params->{args};

    my $resp = {};
    try {
        my $platform = BOM::TradingPlatform->new(
            platform => $args->{platform},
            client   => $client,
        );

        my $platform_assets = $platform->get_assets($args->{type} // '', $args->{region} // 'row',);

        # Translating from BOM::TradingPlatform data model to RPC data model
        my @output_fields = qw(symbol bid ask spread day_percentage_change display_order market shortcode);
        my @output_assets = map {
            my $obj = $_;
            +{map { $_ => $obj->{$_} } @output_fields}
        } $platform_assets->@*;

        $resp->{$args->{platform}}->{assets} = \@output_assets;

        return $resp;

    } catch ($e) {
        handle_error($e);
    }
    };

rpc trading_platform_available_accounts => sub {
    my $params = shift;

    my $client = $params->{client};

    try {
        my $platform = BOM::TradingPlatform->new(
            platform    => $params->{args}{platform},
            client      => $client,
            user        => $client->user,
            rule_engine => BOM::Rules::Engine->new(client => $client),
        );

        return $platform->available_accounts({
            country_code => $client->residence,
            brand        => request()->brand,
        });
    } catch ($e) {
        handle_error($e);
    }
};

=head2 trading_platform_new_account

Create new account.

=cut

rpc trading_platform_new_account => sub {
    my $params = shift;
    my $client = $params->{client};

    try {
        if ($params->{args}{platform} eq 'dxtrade') {
            my $error = BOM::RPC::v3::Utility::set_trading_password_new_account($params->{client}, $params->{args}{password});
            die +{error_code => $error} if $error;
        }

        my $platform = BOM::TradingPlatform->new(
            platform    => $params->{args}{platform},
            client      => $client,
            user        => $client->user,
            rule_engine => BOM::Rules::Engine->new(client => $client),
        );

        # Deiv-Ez termination process has been initiated
        die +{code => 'DerivEZUnavailable'} if $params->{args}{platform} eq 'derivez';

        my $account = $platform->new_account($params->{args}->%*);

        BOM::Platform::Event::Emitter::emit(
            'trading_platform_account_created',
            {
                loginid    => $client->loginid,
                properties => {
                    first_name   => $client->first_name,
                    login        => $account->{login},
                    account_id   => $account->{account_id},
                    account_type => $account->{account_type},
                    market_type  => $account->{market_type},
                    platform     => $params->{args}{platform},
                }});
        return $account;
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
        my $accounts = [];
        my $platform = BOM::TradingPlatform->new(
            platform => $params->{args}{platform},
            client   => $params->{client},
            user     => $params->{client}->user,
        );

        # force param will raise an error if any accounts are inaccessible
        $accounts = $platform->get_accounts             if any { $params->{args}{platform} eq $_ } qw/mt5 derivez ctrader/;
        $accounts = $platform->get_accounts(force => 1) if $params->{args}{platform} eq 'dxtrade';

        return $accounts;
    } catch ($e) {
        return handle_error($e);
    }
};

=head2 trading_servers

    $trading_servers = trading_servers()

Takes a single C<$params> hashref containing the following keys:

=over 4

=item * client (deriv client object)

=over 4

=item * args which contains the following keys:

=item * platform: mt5 or dxtrade

=back

=back

Returns an array of hashes for trade server config, sorted by
recommended flag and sorted by region

=cut

async_rpc trading_servers => sub {
    my $params = shift;

    my $client   = $params->{client};
    my $platform = $params->{args}{platform};

    return BOM::RPC::v3::MT5::Account::get_mt5_server_list(
        client       => $client,
        residence    => $client->residence,
        account_type => $params->{args}{account_type} // 'real',
        market_type  => $params->{args}{market_type},
    ) if ($platform eq 'mt5');

    return get_dxtrade_server_list(
        client       => $client,
        account_type => $params->{args}{account_type},
    ) if ($platform eq 'dxtrade');
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

    my $client = $params->{client};
    my $user   = $client->user;

    try {
        my $new_password     = $params->{args}{new_password} or die +{error_code => 'PasswordRequired'};
        my $old_password     = $params->{args}{old_password};
        my $platform         = $params->{args}{platform};
        my $current_password = $platform eq 'dxtrade' ? $user->dx_trading_password : $user->trading_password;

        if ($current_password) {
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

        change_platform_passwords($new_password, 'change', $params);
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

my %CREATED_FOR = (
    mt5     => 'trading_platform_mt5_password_reset',
    dxtrade => 'trading_platform_dxtrade_password_reset',
);

async_rpc trading_platform_password_reset => auth => ['trading', 'wallet'],
    sub {
    my $params = shift;

    try {
        my $new_password = $params->{args}{new_password} or die +{error_code => 'PasswordRequired'};
        my $platform     = $params->{args}{platform};

        my $token = delete $params->{args}{verification_code};
        my $email = $params->{client}->{email};

        my $error = BOM::RPC::v3::Utility::is_verification_token_valid($token, $email, $CREATED_FOR{$platform})->{error};
        die $error if $error;

        $error = BOM::RPC::v3::Utility::check_password({
            email        => $email,
            new_password => $new_password
        });
        die $error->{error} if $error;

        my $user = BOM::User->new(email => $email);
        $params->{client} = $user->get_default_client();

        change_platform_passwords($new_password, 'reset', $params);
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

        change_investor_password($client, $account_id, $old_password, $new_password, 'change', $params);

        return Future->done(1);
    } catch ($e) {
        Future->fail(handle_error($e));
    }
};

=head2 trading_platform_investor_password_reset

Reset the Trading Platform investor password of the account.

Returns a L<Future> which resolves to C<1> on success.

=cut

async_rpc trading_platform_investor_password_reset => auth => ['trading', 'wallet'],
    => sub {
    my $params = shift;

    try {
        my $account_id = $params->{args}{account_id};
        my $password   = $params->{args}{new_password};
        die +{error_code => 'PasswordRequired'} unless $password;

        my $verification_code = delete $params->{args}{verification_code};
        my $email             = $params->{client}->{email};

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

        change_investor_password($client, $account_id, undef, $password, 'reset', $params);

        return Future->done(1);
    } catch ($e) {
        Future->fail(handle_error($e));
    }
    };

=head2 deposit

Platform deposit implementation.
This method is called in 2 ways: normal websocket call, and internally from transfer_between_accounts.

=cut

sub deposit {
    my $params = shift;
    # Note `transfer_between_accounts` may pass `currency` param, which we should validate.
    # The validation will always pass for `transfer_between_deposit` and `transfer_between_withdrawal`
    # as they don't pass the `currency` param, we use the account currency instead which should be valid.

    my ($from_account, $to_account, $amount, $currency) = $params->{args}->@{qw/from_account to_account amount currency/};

    my $user     = $params->{user}                       // $params->{client}->user;    # reuse user object when called from transfer_between_accounts
    my $details  = $user->loginid_details->{$to_account} // {};
    my $is_topup = $details->{is_virtual} && !$details->{wallet_loginid};

    try {
        die +{error_code => 'PlatformTransferRealParams'} unless $is_topup or ($from_account and $amount);

        my $client = $is_topup ? $params->{client} : get_transfer_client($params, $from_account);

        my $platform = BOM::TradingPlatform->new(
            platform    => $params->{args}{platform},
            client      => $client,
            user        => $user,
            rule_engine => BOM::Rules::Engine->new(
                client => $client,
                user   => $user
            ),
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
This method is called in 2 ways: normal websocket call, and internally from transfer_between_accounts.

=cut

sub withdrawal {
    my $params = shift;

    my ($from_account, $to_account, $amount, $currency) = $params->{args}->@{qw/from_account to_account amount currency/};

    try {
        my $client = get_transfer_client($params, $to_account);
        my $user   = $params->{user} // $client->user;

        my $platform = BOM::TradingPlatform->new(
            platform    => $params->{args}{platform},
            client      => $client,
            user        => $user,
            rule_engine => BOM::Rules::Engine->new(
                client => $client,
                user   => $user
            ),
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
        if (my $code = $e->{error_code} // $e->{code} // $e->{error}->{code}) {
            if (my $message = $e->{message_to_client} // $ERROR_MAP{$code} // BOM::RPC::v3::Utility::error_map()->{$code}
                // BOM::Platform::Utility::error_map()->{$code})
            {
                return BOM::RPC::v3::Utility::create_error({
                    code              => $code,
                    message_to_client => localize($message, ($e->{params} // [])->@*),
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

=item * C<password> (required): the new password

=item * C<type> (required): change or reset

=item * C<params> (required): RPC params

=back

Returns undef on success, dies on error.

=cut

sub change_platform_passwords {
    my ($password, $type, $params) = @_;

    my $client     = $params->{client};
    my $brand      = request()->brand;
    my $brand_name = ($brand->name eq 'deriv' ? 'DMT5' : 'MT5');

    my $contact_url = $brand->contact_url({
            source   => $params->{source},
            language => $params->{language}});

    my $platform_name = $params->{args}{platform};

    my $platform = BOM::TradingPlatform->new(
        platform => $platform_name,
        client   => $client,
        user     => $client->user,
    );

    my $updated_logins = $platform->change_password(password => $password);

    my ($successful_logins, $failed_logins) = $updated_logins->@{qw/successful_logins failed_logins/};

    my $display_name = BOM::RPC::v3::Utility::trading_platform_display_name($platform_name);

    my ($error_message);

    if ($failed_logins) {

        $error_message =
            localize("Due to a network issue, we couldn't update your [_1] password. Please check your email for more details", $brand_name);

        send_email({
                to            => $client->email,
                subject       => localize('Unsuccessful [_1] password change', $display_name),
                template_name => 'reset_password_confirm',
                template_args => {
                    email                             => $client->email,
                    name                              => $client->first_name,
                    title                             => localize("There was an issue with changing your [_1] password", $display_name),
                    contact_url                       => $contact_url,
                    is_trading_password_change_failed => 1,
                    successful_logins                 => $successful_logins,
                    failed_logins                     => $failed_logins,
                    display_name                      => $display_name,
                    platform                          => $platform_name,
                },
                use_email_template => 1,
                template_loginid   => $client->loginid,
                use_event          => 1,
            });

        BOM::Platform::Event::Emitter::emit(
            'trading_platform_password_change_failed',
            {
                loginid    => $client->loginid,
                properties => {
                    first_name        => $client->first_name,
                    contact_url       => $contact_url,
                    type              => $type,
                    successful_logins => $successful_logins,
                    failed_logins     => $failed_logins,
                    platform          => $platform_name,
                }});
    } else {

        send_email({
                from          => $brand->emails('no-reply'),
                to            => $client->email,
                subject       => localize('Your new [_1] password', $display_name),
                template_name => 'reset_password_confirm',
                template_args => {
                    email               => $client->email,
                    name                => $client->first_name,
                    title               => localize("You've got a new [_1] password", $display_name),
                    contact_url         => $contact_url,
                    is_trading_password => 1,
                    logins              => $successful_logins,
                    display_name        => $display_name,
                    platform            => $platform_name,
                },
                use_email_template => 1,
                template_loginid   => $client->loginid,
                use_event          => 1,
            });

        BOM::Platform::Event::Emitter::emit(
            'trading_platform_password_changed',
            {
                loginid    => $client->loginid,
                properties => {
                    first_name  => $client->first_name,
                    contact_url => $contact_url,
                    type        => $type,
                    logins      => $successful_logins,
                    platform    => $platform_name,
                }});
    }

    die +{
        code              => 'PlatformPasswordChangeError',
        message_to_client => $error_message,
    } if $error_message;

    return;
}

=head2 change_investor_password

Common code to handle MT5 investor password change.

=over 4

=item * C<client> (required): Client instance

=item * C<account_id> (required): MT5 account id

=item * C<old_password> (required): the old password

=item * C<new_password> (required): the new password

=item * C<type> (required): change or reset

=item * C<params> (required): RPC params

=back

Returns undef on success, dies on error.

=cut

sub change_investor_password {
    my ($client, $account_id, $old_password, $new_password, $type, $params) = @_;

    my $brand       = request()->brand;
    my $contact_url = $brand->contact_url({
            source   => $params->{source},
            language => $params->{language}});

    my $platform = BOM::TradingPlatform->new(
        platform => 'mt5',
        client   => $client,
        user     => $client->user,
    );

    $platform->change_investor_password(
        old_password => $old_password,
        new_password => $new_password,
        account_id   => $account_id
    )->else(
        sub {
            my $error = shift;
            if (ref $error eq 'HASH' && $error->{code}) {
                die $error if $error->{code} =~ qr/^(InvalidPassword|SameAsMainPassword)$/;
            }

            BOM::Platform::Event::Emitter::emit(
                'trading_platform_investor_password_change_failed',
                {
                    loginid    => $client->loginid,
                    properties => {
                        first_name  => $client->first_name,
                        contact_url => $contact_url,
                        type        => $type,
                        login       => $account_id,
                    }});

            die +{
                code              => 'PlatformInvestorPasswordChangeError',
                message_to_client => localize(
                    "Due to a network issue, we're unable to update your investor password for the following account: [_1]. Please wait for a few minutes before attempting to change your investor password for the above account.",
                    $account_id
                )};
        })->get;

    my $account_info = $platform->get_account_info($account_id);
    my $email        = $client->email;

    my $display_name = BOM::RPC::v3::Utility::trading_platform_display_name('mt5');

    send_email({
            from          => $brand->emails('no-reply'),
            to            => $email,
            subject       => localize('Your new [_1] investor password', $display_name),
            template_name => 'reset_password_confirm',
            template_args => {
                name                 => $client->first_name,
                title                => localize("You've got a new [_1] investor password", $display_name),
                login                => $account_id,
                email                => $email,
                contact_url          => $contact_url,
                is_investor_password => 1
            },
            use_event             => 1,
            use_email_template    => 1,
            email_content_is_html => 1,
            template_loginid      => ucfirst $account_info->{account_type} . ' ' . $account_id =~ s/${\BOM::User->MT5_REGEX}//r,
        });

    BOM::Platform::Event::Emitter::emit(
        'trading_platform_investor_password_changed',
        {
            loginid    => $client->loginid,
            properties => {
                first_name  => $client->first_name,
                contact_url => $contact_url,
                type        => $type,
                login       => $account_id,
            }});

    return;
}

=head2 get_dxtrade_server_list

    get_dxtrade_server_list(client => $client, account_type => 'real');

    Return the array of hash of trade servers configuration for Deriv X.

=cut

sub get_dxtrade_server_list {
    my (%args) = @_;

    my ($client, $account_type) = @args{qw/client account_type/};
    return Future->done([]) unless $client->residence;

    my @active_servers = BOM::TradingPlatform::DXTrader->new(client => $client)->active_servers;
    my $brand          = request()->brand;
    my $countries      = $brand->countries_instance;

    local $log->context->{brand_name}       = $brand->name;
    local $log->context->{app_id}           = $brand->app_id;
    local $log->context->{client_residence} = $client->residence;

    my @market_types = grep {
        local $log->context->{account_type} = $_;
        (
            $countries->dx_company_for_country(
                country      => $client->residence,
                account_type => $_
            ) // ''
        ) ne 'none'
    } qw/all/;

    return Future->done([]) unless @market_types;

    my @servers = map { {account_type => $_} } grep { not $account_type or $account_type eq $_ } qw/real demo/;

    for my $server (@servers) {
        $server->{disabled}           = (none { $server->{account_type} eq $_ } @active_servers) ? 1 : 0;
        $server->{supported_accounts} = \@market_types;
    }

    return Future->done(\@servers);
}

=head2 trading_platform_leverage

Returns dynamic leverage details data for the platform, defaults to mt5

=over 4

=item * platform - a string to represent trading platform. (E.g. mt5)

=back

=cut

rpc trading_platform_leverage => auth => [],
    sub {
    return {leverage => BOM::Config::dynamic_leverage_config()};
    };

1;
