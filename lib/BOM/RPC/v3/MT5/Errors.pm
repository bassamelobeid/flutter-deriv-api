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

my $category_message_mapping = {
    General                    => 'A connection error happened while we were completing your request. Please try again later.',
    MT5APISuspendedError       => 'MT5 is currently unavailable. Please try again later.',
    MT5DepositSuspended        => 'Deposits are currently unavailable. Please try again later.',
    MT5WithdrawalSuspended     => 'Withdrawals are currently unavailable. Please try again later.',
    PaymentsSuspended          => 'Payments are currently unavailable. Please try again later.',
    SetExistingAccountCurrency => 'Please set your account currency.',
    InvalidAccountType         => "We can't find this account. Please check the details and try again.",
    MT5SamePassword            => 'Please use different passwords for your investor and main accounts.',
    InvalidSubAccountType      => "We can't find this account. Please check the details and try again.",
    Throttle                   => 'It looks like you have already made the request. Please try again later.',
    MT5PasswordChangeError     => "You've used this password before. Please create a different one.",
    DemoTopupThrottle          => 'We are processing your top-up request. Please wait for your virtual funds to be credited.',
    DemoTopupBalance =>
        'We cannot complete your request. You can only ask for additional virtual funds if your demo account balance falls below [_1] [_2].',
    TransferSuspended    => 'Transfers between fiat and crypto accounts are currently unavailable. Please try again later.',
    CurrencySuspended    => 'Transfers between [_1] and [_2] are currently unavilable. Please try again later.',
    ClientFrozen         => 'We are completing your request. Please give us a few more seconds.',
    MT5AccountLocked     => 'Your MT5 account is locked. Please contact us for more information.',
    NoExchangeRates      => 'Transfers are unavailable on weekends. Please try again anytime from Monday to Friday.',
    NoTransferFee        => 'Transfers are currently unavailable between [_1] and [_2]. Please use a different currency or try again later.',
    AmountNotAllowed     => 'The minimum amount for transfers is [_1] [_2]. Please adjust your amount.',
    InvalidMinAmount     => 'The minimum amount for transfers is [_1] [_2]. Please adjust your amount.',
    InvalidMaxAmount     => 'The maximum amount for deposits is [_1] [_2]. Please adjust your amount.',
    InvalidPassword      => 'We cannot log you in. Please enter your password.',
    NoMoney              => 'Your withdrawal is unsuccessful. Please make sure you have enough funds in your account.',
    HaveOpenPositions    => 'Please withdraw your account balance and close all your open positions before revoking MT5 account manager permissions.',
    MissingSignupDetails => 'Your profile appears to be incomplete. Please update your personal details to continue.',
    NoAccountDetails     => 'We are retrieving your MT5 details. Please give us a few more seconds.',
    NoCitizen            => 'Please indicate your citizenship.',
    RealAccountMissing   => 'You are on a virtual account. To open an MT5 account, please upgrade to a real account.',
    FinancialAccountMissing => 'Your existing account does not allow MT5 trading. To open an MT5 account, please upgrade to a financial account.',
    GamingAccountMissing    => 'Your existing account does not allow MT5 trading. To open an MT5 account, please upgrade to a gaming account.',
    NoAgeVerification       => "You haven't verified your age. Please contact us for more information.",
    FinancialAssessmentMandatory => 'Please complete our financial assessment.',
    TINDetailsMandatory          => 'We require your tax information for regulatory purposes. Please fill in your tax information.',
    MT5Duplicate  => "An account already exists with the information you provided. If you've forgotten your username or password, please contact us.",
    MissingID     => 'Your login ID is missing. Please check the details and try again.',
    MissingAmount => 'Please enter the amount you wish to transfer.',
    WrongAmount   => 'Please enter a valid amount you wish to transfer.',
    MT5NotAllowed => 'MT5 [_1] account is not available in your country yet.',
    MT5CreateUserError           => 'An error occured while creating your account. Please check your information and try again.',
    NoDemoWithdrawals            => 'Withdrawals are not possible for demo accounts.',
    InvalidLoginid               => "We can't find this login ID in our database. Please check the details and try again.",
    NoManagerAccountWithdraw     => 'Withdrawals from MT5 manager accounts is not possible. Please choose another payment method.',
    AuthenticateAccount          => "You haven't authenticated your account. Please contact us for more information.",
    MT5TransfersLocked           => 'It looks like your account is locked for MT5 transfers. Please contact us for more information.',
    SwitchAccount                => 'This account does not allow MT5 trading. Please log in to the correct account.',
    AccountDisabled              => "We've disabled your MT5 account. Please contact us for more information.",
    CashierLocked                => 'Your account cashier is locked. Please contact us for more information.',
    MaximumTransfers             => 'You can only perform up to [_1] transfers a day. Please try again tomorrow.',
    CannotGetOpenPositions       => 'A connection error happened while we were completing your request. Please try again later.',
    WithdrawalLocked             => 'You cannot perform this action, as your account is withdrawal locked.',
    TransferBetweenAccountsError => 'Transfers between accounts are not available for your account.',
    CurrencyConflict             => 'Currency provided is different from account currency.',
    InvalidMT5Group              => 'This MT5 account has an invalid Landing Company.',
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

    my $message = $category_message_mapping->{$error_code} || $category_message_mapping->{'General'};
    my @params;
    my $details;
    if (ref $options eq 'HASH') {
        $message    = $options->{message}       if $options->{message};
        $error_code = $options->{override_code} if $options->{override_code};
        @params = ref $options->{params} eq 'ARRAY' ? @{$options->{params}} : ($options->{params}) if exists $options->{params};
        $details = $options->{details} if $options->{details};
    }

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
