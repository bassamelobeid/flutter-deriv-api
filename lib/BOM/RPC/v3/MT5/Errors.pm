package BOM::RPC::v3::MT5::Errors;

use strict;
use warnings;

use BOM::RPC::v3::Utility;
use BOM::Platform::Context qw (localize request);

=head1 BOM::RPC::v3::MT5::Errors

Errors package for BOM::RPC::v3::MT5::Account

=head2 $category_message_mapping

The hash mapping the error code to the message content

=cut

my %category_message_mapping = do {
    ## no critic(TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'redefine';
    local *localize = sub { die 'invalid parameter list - expecting a single string' unless @_ == 1; shift };
    (
        General                    => localize('A connection error happened while we were completing your request. Please try again later.'),
        MT5APISuspendedError       => localize('MT5 is currently unavailable. Please try again later.'),
        MT5DepositSuspended        => localize('Deposits are currently unavailable. Please try again later.'),
        MT5WithdrawalSuspended     => localize('Withdrawals are currently unavailable. Please try again later.'),
        PaymentsSuspended          => localize('Payments are currently unavailable. Please try again later.'),
        SetExistingAccountCurrency => localize('Please set your account currency.'),
        InvalidAccountType         => localize("We can't find this account. Please check the details and try again."),
        MT5SamePassword            => localize('Please use different passwords for your investor and main accounts.'),
        InvalidSubAccountType      => localize("We can't find this account. Please check the details and try again."),
        Throttle                   => localize('It looks like you have already made the request. Please try again later.'),
        MT5PasswordChangeError     => localize("You've used this password before. Please create a different one."),
        DemoTopupThrottle          => localize('We are processing your top-up request. Please wait for your virtual funds to be credited.'),
        DemoTopupBalance           => localize(
            'We cannot complete your request. You can only ask for additional virtual funds if your demo account balance falls below [_1] [_2].'),
        TransferSuspended => localize('Transfers between fiat and crypto accounts are currently unavailable. Please try again later.'),
        CurrencySuspended => localize('Transfers between [_1] and [_2] are currently unavailable. Please try again later.'),
        ClientFrozen      => localize('We are completing your request. Please give us a few more seconds.'),
        MT5AccountLocked  => localize('Your MT5 account is locked. Please contact us for more information.'),
        NoExchangeRates   => localize('Transfers are unavailable on weekends. Please try again anytime from Monday to Friday.'),
        NoTransferFee => localize('Transfers are currently unavailable between [_1] and [_2]. Please use a different currency or try again later.'),
        AmountNotAllowed           => localize('The minimum amount for transfers is [_1] [_2]. Please adjust your amount.'),
        InvalidMinAmount           => localize('The minimum amount for transfers is [_1] [_2]. Please adjust your amount.'),
        InvalidMaxAmount           => localize('The maximum amount for deposits is [_1] [_2]. Please adjust your amount.'),
        InvalidPassword            => localize('Forgot your password? Please reset your password.'),
        IncorrectMT5PasswordFormat => localize(
            'Your password must have a minimum of 8 characters. It must also have at least 2 out of the following 3 types of characters: uppercase letters, lowercase letters, and numbers.'
        ),
        NoMoney => localize('Your withdrawal is unsuccessful. Please make sure you have enough funds in your account.'),
        HaveOpenPositions =>
            localize('Please withdraw your account balance and close all your open positions before revoking MT5 account manager permissions.'),
        MissingSignupDetails => localize('Your profile appears to be incomplete. Please update your personal details to continue.'),
        NoAccountDetails     => localize('We are retrieving your MT5 details. Please give us a few more seconds.'),
        RealAccountMissing   => localize('You are on a virtual account. To open an MT5 account, please upgrade to a real account.'),
        FinancialAccountMissing =>
            localize('Your existing account does not allow MT5 trading. To open an MT5 account, please upgrade to a financial account.'),
        GamingAccountMissing =>
            localize('Your existing account does not allow MT5 trading. To open an MT5 account, please upgrade to a gaming account.'),
        NoAgeVerification            => localize("You haven't verified your age. Please contact us for more information."),
        FinancialAssessmentMandatory => localize('Please complete your financial assessment.'),
        TINDetailsMandatory          => localize('We require your tax information for regulatory purposes. Please fill in your tax information.'),
        MT5Duplicate                 => localize(
            "An account already exists with the information you provided. If you've forgotten your username or password, please contact us."),
        MissingID                    => localize('Your login ID is missing. Please check the details and try again.'),
        MissingAmount                => localize('Please enter the amount you want to transfer.'),
        WrongAmount                  => localize('Please enter a valid amount to transfer.'),
        MT5NotAllowed                => localize('MT5 [_1] account is not available in your country yet.'),
        MT5CreateUserError           => localize('An error occured while creating your account. Please check your information and try again.'),
        NoDemoWithdrawals            => localize('Withdrawals are not possible for demo accounts.'),
        InvalidLoginid               => localize("We can't find this login ID in our database. Please check the details and try again."),
        NoManagerAccountWithdraw     => localize('Withdrawals from MT5 manager accounts is not possible. Please choose another payment method.'),
        AuthenticateAccount          => localize("You haven't authenticated your account. Please contact us for more information."),
        MT5TransfersLocked           => localize('It looks like your account is locked for MT5 transfers. Please contact us for more information.'),
        SwitchAccount                => localize('This account does not allow MT5 trading. Please log in to the correct account.'),
        AccountDisabled              => localize("We've disabled your MT5 account. Please contact us for more information."),
        CashierLocked                => localize('Your account cashier is locked. Please contact us for more information.'),
        MaximumTransfers             => localize('You can only perform up to [_1] transfers a day. Please try again tomorrow.'),
        CannotGetOpenPositions       => localize('A connection error happened while we were completing your request. Please try again later.'),
        WithdrawalLocked             => localize('You cannot perform this action, as your account is withdrawal locked.'),
        TransferBetweenAccountsError => localize('Transfers between accounts are not available for your account.'),
        CurrencyConflict             => localize('Currency provided is different from account currency.'),
        InvalidMT5Group              => localize('This MT5 account has an invalid Landing Company.'),
        VirtualProhibited            => localize('You cannot perform this action with a virtual account.'),
    );
};

=head2 new

BOM::RPC::v3::MT5::Errors->new();

=cut

sub new {
    my ($class) = @_;
    return bless {}, $class;
}

=head2 format_error

formated error accoridng to given params

=over 4

=item * C<error_code> - the error_code to get the mapping message.

=item * C<options> - extra params to custom the error content

=back

Return the final formated error hashref accoridng to the error_code

=cut

sub format_error {
    my ($self, $error_code, $options) = @_;

    if (($error_code eq 'permission') and not $options) {
        return BOM::RPC::v3::Utility::permission_error();
    }

    my $message = $category_message_mapping{$error_code};
    my @params;
    my $details;
    if (ref $options eq 'HASH') {
        $message = $options->{message} if $options->{message} && !$message;
        $error_code = $options->{override_code} if $options->{override_code};
        @params = ref $options->{params} eq 'ARRAY' ? @{$options->{params}} : ($options->{params}) if exists $options->{params};
        $details = $options->{details} if $options->{details};
    }

    $message ||= $category_message_mapping{'General'};

    return $self->_create_error($error_code, localize($message, @params), $details);
}

=head2 _create_error

Call BOM::RPC::v3::Utility::create_error to create the common error format

=cut

sub _create_error {
    my ($self, $code, $message, $details) = @_;
    return BOM::RPC::v3::Utility::create_error({
        code              => $code,
        message_to_client => $message,
        details           => $details,
    });
}

1;
