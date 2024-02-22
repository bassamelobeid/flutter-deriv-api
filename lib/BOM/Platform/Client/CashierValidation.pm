package BOM::Platform::Client::CashierValidation;

=head1 NAME

BOM::Platform::Client::CashierValidation

=head1 DESCRIPTION

Handles validation for cashier

=cut

use strict;
use warnings;
no indirect;

use Date::Utility;
use ExchangeRates::CurrencyConverter qw( convert_currency );
use Format::Util::Numbers            qw( get_min_unit financialrounding );
use List::Util                       qw( any none );
use Scalar::Util                     qw( looks_like_number );
use Syntax::Keyword::Try;

use LandingCompany::Registry;

use BOM::Config::CurrencyConfig;
use BOM::Platform::Utility qw(error_map create_error);
use Log::Any               qw( $log );
use BOM::Platform::Event::Emitter;
use BOM::Database::ClientDB;

use BOM::Config::Runtime;
use BOM::Platform::Context qw( request localize );
use BOM::User::Client;

# custom error codes to override the default error code CashierForwardError
use constant OVERRIDE_ERROR_CODES => qw(
    SelfExclusion
    ASK_CURRENCY
    ASK_AUTHENTICATE
    ASK_FINANCIAL_RISK_APPROVAL
    ASK_TIN_INFORMATION
    ASK_UK_FUNDS_PROTECTION
    ASK_SELF_EXCLUSION_MAX_TURNOVER_SET
    ASK_FIX_DETAILS
    FinancialAssessmentRequired
    PaymentAgentWithdrawSameMethod
    PaymentAgentJustification
    PaymentAgentJustificationAdded
    PaymentAgentUseOtherMethod
    PaymentAgentZeroDeposits
    PaymentAgentVirtualClient
);

# error codes that should not pushed to status
use constant SUPPRESSED_CODES_TO_BECOME_STATUS => qw(
    VirtualAccount
    InvalidAccount
    IllegalCurrency
);

# a mapping from error codes to the FE status codes.
my %error_to_status_mapping = (
    NoResidence                       => 'no_residence',
    SetExistingAccountCurrency        => 'ASK_CURRENCY',
    CashierLocked                     => 'cashier_locked_status',
    DisabledAccount                   => 'disabled_status',
    CurrencyNotApplicable             => 'IllegalCurrency',
    DocumentsExpired                  => 'documents_expired',
    NotAuthenticated                  => 'ASK_AUTHENTICATE',
    FinancialRiskNotApproved          => 'ASK_FINANCIAL_RISK_APPROVAL',
    NoTaxInformation                  => 'ASK_TIN_INFORMATION',
    NoUkgcFundsProtection             => 'ASK_UK_FUNDS_PROTECTION',
    NoMaxTuroverLimit                 => 'ASK_SELF_EXCLUSION_MAX_TURNOVER_SET',
    UnwelcomeStatus                   => 'unwelcome_status',
    CashierRequirementsMissing        => 'ASK_FIX_DETAILS',
    NoWithdrawalOrTradingStatus       => 'no_withdrawal_or_trading_status',
    WithdrawalLockedStatus            => 'withdrawal_locked_status',
    HighRiskNotAuthenticated          => 'ASK_AUTHENTICATE',
    PotentialFraud                    => 'ASK_AUTHENTICATE',
    SystemMaintenance                 => 'system_maintenance',
    SystemMaintenanceCrypto           => 'system_maintenance',
    SystemMaintenanceDepositOutage    => 'system_maintenance_deposit_outage',
    SystemMaintenanceWithdrawalOutage => 'system_maintenance_withdrawal_outage',
);

# error codes passed through for crypto_cashier
use constant CRYPTO_PASSTHROUGH_ERROR_CODES => qw(
    PACommisionWithdrawalLimit CryptoLimitAgeVerified
);

=head2 validate

Validates various checks related to cashier including
regulation and compliance requirements.

=over 4

=item * C<client> - An object of the type L<BOM::User::Client>.

=item * C<$loginid> - For creating an instance of L<BOM::User::Client>.

=item * C<action> - takes either deposit or withdraw to include their specific rules.

=item * C<is_internal> - true when this is an internal transfer.

=item * C<is_cashier> - true when this involves an external cashier (doughflow, crypto).

=item * C<rule_engine> - a rule engine object (please note that we are not allowed to create rule engine objects in this repo)

=back

Returns undef for successful validation or a hashref containing error details.

=cut

sub validate {
    my %args = @_;
    my ($loginid, $action, $is_internal, $is_cashier, $underlying_action) = @args{qw(loginid action is_internal is_cashier underlying_action)};

    my $errors = {};
    my $client = delete $args{client} // BOM::User::Client->get_client_instance($loginid, 'replica');

    unless ($client) {
        _add_error_by_code($errors, 'InvalidAccount');
        return $errors;
    }

    $action =~ s/^withdraw$/withdrawal/;

    my $rule_engine = delete $args{rule_engine};

    $underlying_action //= {};
    $underlying_action = {name => $underlying_action} unless ref $underlying_action;

    $errors = check_availability($client, $action) // {};

    my $currency     = $client->account ? $client->account->currency_code : '';
    my $has_deposits = $client->has_deposits();

    my $failed_rules;

    my $rules_result = $rule_engine->verify_action(
        'cashier_validation',
        underlying_action => $underlying_action->{name} // ('cashier_' . $action),
        $underlying_action->{args}->%*,
        loginid      => $loginid,
        action       => $action,
        currency     => $currency,
        is_internal  => $is_internal ? 1 : 0,
        is_cashier   => $is_cashier,
        has_deposits => $has_deposits ? 1 : 0,
        # Keep the rule engine from stopping on failure
        rule_engine_context => {stop_on_failure => 0},
    );

    $failed_rules = $rules_result->failed_rules;

    _convert_rule_failure_to_cashier_error($failed_rules // [], $errors);

    return $errors if $errors->{error};

    return undef;
}

=head2 check_availability

Checks cashier availability. It verifies different global app settings that may suspend payments, cashier or currencies.
There is no business rule checked here.
It takes followng arguments:

=over 4

=item * C<$client> - An object of the type L<BOM::User::Client>.

=item * C<action> - it can be either B<deposit> or B<withdrawal>.

=back

Returns undef for successful validation or a hashref containing error details.

=cut

sub check_availability {
    my ($client, $action) = @_;

    $action =~ s/^withdraw$/withdrawal/;

    my $errors = {};
    _add_error_by_code($errors, 'SystemMaintenance')
        if (BOM::Config::CurrencyConfig::is_payment_suspended());

    _add_error_by_code($errors, 'VirtualAccount')
        if $client->is_virtual && $client->is_legacy;

    return $errors if $errors->{error};

    my $currency      = $client->account ? $client->account->currency_code : '';
    my $currency_type = LandingCompany::Registry::get_currency_type($currency);

    _add_error_by_code($errors, 'SystemMaintenance')
        if $currency_type eq 'fiat' and BOM::Config::CurrencyConfig::is_cashier_suspended();

    _add_error_by_code($errors, 'SystemMaintenanceCrypto')
        if $currency_type eq 'crypto'
        and (BOM::Config::CurrencyConfig::is_crypto_cashier_suspended() or BOM::Config::CurrencyConfig::is_crypto_currency_suspended($currency));

    _add_error_by_code($errors, 'SystemMaintenanceDepositOutage', params => [$currency])
        if $currency_type eq 'crypto' && $action eq 'deposit' && BOM::Config::CurrencyConfig::is_crypto_currency_deposit_suspended($currency);

    _add_error_by_code($errors, 'SystemMaintenanceWithdrawalOutage', params => [$currency])
        if $currency_type eq 'crypto' && $action eq 'withdrawal' && BOM::Config::CurrencyConfig::is_crypto_currency_withdrawal_suspended($currency);

    return $errors;
}

=head2 invalid_currency_error

Generate standard error parameters if currency is invalid.

=over 4

=item * C<currency> - The currency code to check the validity of. B<case-sensitive>

=back

Returns a hashref containing error parameters if currency is invalid, otherwise C<undef>.

=cut

sub invalid_currency_error {
    my ($currency) = @_;

    return undef if BOM::Config::CurrencyConfig::is_valid_currency($currency);

    return {
        code              => 'InvalidCurrency',
        params            => [$currency],
        message_to_client => BOM::Platform::Context::localize('The provided currency [_1] is invalid.', $currency),
    };
}

=head2 calculate_to_amount_with_fees

Calculates transfer amount and fees

Takes for the following named args:

=over 4

=item * C<amount> - The amount is be transferred (in the currency of the sending account)

=item * C<from_currency> - The currency of the sending account

=item * C<to_currency> - The currency of the receiving account

=item * C<country> - to determine country specific fees, optional

=item * C<from_client> - A L<BOM::User::Client> instance of the sending client
Optional: only required to ascertain if client qualifies for PA fee exemption

=item * C<to_client> - A L<BOM::User::Client> instance of the receiving client
Optional: only required to ascertain if client qualifies for PA fee exemption

=back

Returns

=over 4

=item * The amount that will be received (in the currency of the receiving account)

=item * The fee charged to the sender (in the currency of the sending account). It is maximum of minimum fee and calculated fee.

=item * The fee percentage applied for transfers between these currencies

B<Note>: If a minimum fee was enforced then this will not reflect the actual fee charged.

=item * Minimum fee amount allowed for the sending account's currency (minimum currency unit).

=item * The fee amount calculated by the fee percent alone (before comparing to the minimum fee).

=back

=cut

sub calculate_to_amount_with_fees {
    my %args = @_;

    my ($amount, $from_currency, $to_currency, $fm_client, $to_client, $country) =
        @args{qw(amount from_currency to_currency from_client to_client country)};

    my $rate_expiry = BOM::Config::CurrencyConfig::rate_expiry($from_currency, $to_currency);

    return ($amount, 0, 0, 0, 0) if $from_currency eq $to_currency;

    # Fee exemption for transfers between an authorised payment agent account and another account under that user.
    return (convert_currency($amount, $from_currency, $to_currency, $rate_expiry), 0, 0, 0, 0)
        if (defined $fm_client
        && defined $to_client
        && $fm_client->is_same_user_as($to_client)
        && ($fm_client->is_pa_and_authenticated() || $to_client->is_pa_and_authenticated()));

    my $currency_config = BOM::Config::CurrencyConfig::transfer_between_accounts_fees($country);
    my $fee_percent     = $currency_config->{$from_currency}->{$to_currency};

    die "No transfer fee found for $from_currency-$to_currency" unless defined $fee_percent;

    my $fee_calculated_by_percent = $amount * $fee_percent / 100;

    my $min_fee = get_min_unit($from_currency);
    my $fee_applied;

    if ($fee_percent == 0) {
        $fee_applied = 0;
    } elsif ($fee_calculated_by_percent < $min_fee) {
        $fee_applied = $min_fee;
    } else {
        $fee_applied = $fee_calculated_by_percent;
    }

    $amount = convert_currency(($amount - $fee_applied), $from_currency, $to_currency, $rate_expiry);

    die "The amount ($amount) is below the minimum allowed amount (" . get_min_unit($to_currency) . ") for $to_currency."
        if $amount < get_min_unit($to_currency);

    return ($amount, $fee_applied, $fee_percent, $min_fee, $fee_calculated_by_percent);
}

=head2 _add_error_by_code

Takes the first error message and accumulated FE codes, just like B<_add_error>; but it takes error codes 
and generates localized error messages.

=over 4

=item * C<current> - hashref to be updated in-place.

=item * C<code> - error code to be returned by api, optional.

=item * C<args> - hashref of additional error info, like B<details> and message localization B<params>.

=back

Returns nothing.

=cut

sub _add_error_by_code {
    my ($current, $code, %args) = @_;

    # get params and pour in an array
    my @params = ();
    if ($args{params}) {
        @params = ref $args{params} eq 'ARRAY' ? $args{params}->@* : ($args{params});
    }

    # make localized message based on original code and the params
    my $message = localize(error_map()->{$code}, @params);

    # map error code to status (FE requires)
    $code = $error_to_status_mapping{$code} // $code;

    # override codes if needed to a general code (FE requires)
    my $overrided_code = $code;
    $overrided_code = 'CashierForwardError' unless any { $code and $code eq $_ } OVERRIDE_ERROR_CODES;

    my $details = $args{details};

    # put unified error hash into current error instance
    $current->{error} //= {
        code              => $overrided_code,
        params            => \@params,
        message_to_client => $message,
        $details ? (details => $details) : (),
    };

    # push code to statuses list if not suppressed
    push $current->{status}->@*, $code if $code and none { $_ eq $code } SUPPRESSED_CODES_TO_BECOME_STATUS;

    $current->{missing_fields} = $details->{fields} if $code && ($code eq 'ASK_FIX_DETAILS');
}

=head2 _convert_rule_failure_to_cashier_error

Processes the list of failures returned by rule-engine and 
adds combines them into the pre-existing error using B<_add_error_by_code>.
It takes the following args:

=over 4

=item * C<rule_failures> - Arrayref of faulures 

=item * C<errors> - previous cashier validation errors combined into a single hash-ref.

=back

Returns nothing.

=cut

sub _convert_rule_failure_to_cashier_error {
    my ($rule_failures, $errors) = @_;

    return 1 unless scalar @$rule_failures;

    # if the first rule has failed with exception, there's something basically wrong.
    die $rule_failures->[0] unless ref $rule_failures->[0];

    for my $failure (@$rule_failures) {
        last unless ref $failure;

        _add_error_by_code($errors, $failure->{error_code}, %$failure);
    }

    return 1;
}

=head2 validate_crypto_withdrawal_request

Client-related validatation from a withdrwarl request

Receives the following parameter:

=over 4

=item * C<$client> - Client object

=item * C<$address> - Withdrawal address

=item * C<$amount> - Withdrawal amount

=item * C<$rule_engine> - Rule engine object

=back

Returns C<undef> in case of successful, otherwise a hashref for error details.

=cut

sub validate_crypto_withdrawal_request {
    my ($client, $address, $amount, $rule_engine) = @_;

    return create_error(
        'CryptoMissingRequiredParameter',
        details => {'field' => 'address'},
    ) unless ($address);

    return create_error(
        'CryptoMissingRequiredParameter',
        details => {'field' => 'amount'},
    ) unless ($amount);

    # validate withdrawal
    my $error = validate_payment_error($client, $amount, $rule_engine);
    return $error if $error;

    return create_error('CryptoWithdrawalNotAuthenticated')
        if check_crypto_deposit($client);

    return;
}

=head2 validate_payment_error

Checks if there is any error from C<BOM::User::Client::validate_payment>
and return proper error message based on that.

Receives the following parameter:

=over 4

=item * C<$client> - Client object

=item * C<$amount> - Negative number for withdrawal amount

=item * C<$rule_engine> - Rule engine object

=back

Returns C<undef> in case of successful, otherwise a hashref for error details.

=cut

sub validate_payment_error {
    my ($client, $amount, $rule_engine) = @_;
    my $currency_code = $client->default_account->currency_code;
    my $cashier_validation_failure;

    try {
        $client->validate_payment(
            currency     => $currency_code,
            amount       => -1 * $amount,
            payment_type => 'crypto_cashier',
            rule_engine  => $rule_engine,
        );
    } catch ($e) {
        $cashier_validation_failure = $e;
    }

    return undef unless $cashier_validation_failure;

    my $error_code = $cashier_validation_failure->{code};

    if ($error_code eq 'WithdrawalLimit') {
        my $limit = $cashier_validation_failure->{params}[0];
        return create_error('CryptoWithdrawalLimitExceeded', message_params => [abs($amount), $currency_code, $limit]);
    }

    if ($error_code eq 'AmountExceedsBalance') {
        my $balance = $cashier_validation_failure->{params}[2];
        return create_error('CryptoWithdrawalBalanceExceeded', message_params => [abs($amount), $currency_code, $balance]);
    }

    if ($error_code eq 'WithdrawalLimitReached') {
        my ($limit, $currency) = @{$cashier_validation_failure->{params}}[0, 1];
        return create_error('CryptoWithdrawalMaxReached', message_params => [$limit, $currency]);
    }

    if (any { $_ eq $error_code } CRYPTO_PASSTHROUGH_ERROR_CODES) {
        return create_error($error_code, message_params => $cashier_validation_failure->{params});
    }

    # In this case we are not handling the issue so we need
    # to log it to identify what is happening.
    $log->errorf("Unhandled payment validation error: %s", $cashier_validation_failure);
    return create_error('CryptoWithdrawalError');
}

=head2 get_restricted_countries

This sub will get the list of restricted countries set

=cut

sub get_restricted_countries {
    return BOM::Config::Runtime->instance->app_config->payments->crypto->restricted_countries;
}

=head2 check_crypto_deposit

This sub will check if the user has deposited through crypto if the client's residence is in C<restricted_countries>.

=over 4

=item * C<$client> - Client object

=back

Returns 0 in case of success, otherwise 1.

=cut

sub check_crypto_deposit {
    my ($client) = @_;

    my $restricted_countries = get_restricted_countries();
    my $client_residence     = uc $client->residence;

    # Perform this check only when the client is from restricted country
    return 0 if none { uc $_ eq $client_residence } @$restricted_countries;

    # since we don't run this check for authenticated clients, also skip if landing company has no KYC
    return 0 if $client->landing_company->skip_authentication;

    my $clientdb_dbic = BOM::Database::ClientDB->new({
            client_loginid => $client->loginid,
        })->db->dbic;

    my $has_crypto_deposit = $clientdb_dbic->run(
        fixup => sub {
            $_->selectrow_hashref(
                "SELECT ctc_is_first_deposit AS is_first_deposit FROM payment.ctc_is_first_deposit(?)",
                {Slice => {}},
                [$client->user->bom_real_loginids]);
        });

    if ($has_crypto_deposit->{is_first_deposit} and not $client->fully_authenticated()) {

        BOM::Platform::Event::Emitter::emit(
            'crypto_withdrawal',
            {
                loginid => $client->loginid,
                error   => 'no_crypto_deposit'
            });

        return 1;
    }

    return 0;
}

1;
