package BOM::Platform::Utility;

use strict;
use warnings;

use Clone::PP qw(clone);
use List::Util qw(any);
use Brands::Countries;

use BOM::Platform::Context qw/localize/;
use BOM::Config::Runtime;

use base qw( Exporter );
our @EXPORT_OK = qw(error_map create_error);

=head1 NAME

BOM::Platform::Utility

=head1 DESCRIPTION

A collection of helper methods.

=cut

=head2 hash_to_array

Extract values from a hashref and returns as an arrayref.

It takes a hashref:

=over 4

=item * C<hash> an input hashref 

Example:
    $input: {
        a => ['1', '2', '3'],
        b => {
            c => ['4', '5', '6'],
            d => ['7', '8', '9'],
        }
    }
    # see test

=back

Returns an arrayref.

Example:
    $output: ['1', '2', '3', '4', '5', '6', '7', '8', '9'];

=cut

sub hash_to_array {
    my ($hash) = @_;
    return _hash_to_array_helper([], [clone($hash)]);
}

=head2 _hash_to_array_helper

Recursively calls itself and extract values from a hashref $stack.

It takes:

=over 4

=item * C<array> an arrayref that holds the output values 

=item * C<stack> an arrayref of a copy of input hash

=back

Returns an arrayref that holds the values of a hash.

=cut

sub _hash_to_array_helper {
    my ($array, $stack) = @_;

    return $array unless $stack->@*;

    my $temp_stack = [];
    foreach my $value ($stack->@*) {
        next unless defined $value;

        my $refs = $value;
        $refs = [$value] unless ref $value eq 'ARRAY';

        for ($refs->@*) {
            push $temp_stack->@*, values $_->%* if ref $_ eq 'HASH';
            push $temp_stack->@*, $_->@*        if ref $_ eq 'ARRAY';
            push $array->@*,      $_ unless ref $_;
        }
    }
    return _hash_to_array_helper($array, $temp_stack);
}

=head2 extract_valid_params

Extract valid params by testing againest regex

=over 4

=item * C<params> fields to be filtered

=item * C<args> values of C<params>

=item * C<regex_validation_keys> hash contains key and value regex as key/value pair.

=back

Returns valid params

=cut

sub extract_valid_params {
    my ($params, $args, $regex_validation_keys) = @_;

    my %filtered_params;
    my @remaining_params = $params->@*;

    foreach my $key_regex (keys $regex_validation_keys->%*) {
        my $value_regex = $regex_validation_keys->{$key_regex};

        %filtered_params = (
            %filtered_params, map { $_ => $args->{$_} }
                grep { defined $args->{$_} && $_ =~ $key_regex && $args->{$_} =~ $value_regex } @remaining_params
        );
        @remaining_params = grep { $_ !~ $key_regex } @remaining_params;
    }

    %filtered_params = (%filtered_params, map { $_ => $args->{$_} } @remaining_params);
    return \%filtered_params;
}

=head2 error_map

Returns a mapping from error codes to error messages as a hash-ref.

=cut

sub error_map {
    ## no critic(TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'redefine';

    local *localize = sub { die 'you probably wanted an arrayref for this localize() call' if @_ > 1; shift };

    return {
        # Cashier validation
        PaymentValidationError => localize('An error occurred while processing your request. Please try again later.'),
        VirtualAccount         => localize('This is a virtual-money account. Please switch to a real-money account to access cashier.'),
        NoResidence            => localize('Please set your country of residence.'),
        CashierLocked          => localize('Your cashier is locked.'),
        DisabledAccount        => localize('Your account is disabled.'),

        DocumentsExpired =>
            localize('Your identity documents have expired. Visit your account profile to submit your valid documents and unlock your cashier.'),
        NotAuthenticated => localize('Please authenticate your account.'),
        NoTaxInformation =>
            localize('Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.'),
        NoMaxTuroverLimit => localize('Please set your 30-day turnover limit in our self-exclusion facilities to access the cashier.'),
        SelfExclusion     => localize(
            'You have chosen to exclude yourself from trading on our website until [_1]. If you are unable to place a trade or deposit after your self-exclusion period, please contact us via live chat.'
        ),
        UnwelcomeStatus => localize('Your account is restricted to withdrawals only.'),

        InternalCashierError              => localize('Sorry, cashier is temporarily unavailable. Please try again later.'),
        system_maintenance                => localize('Sorry, cashier is temporarily unavailable due to system maintenance.'),
        SystemMaintenance                 => localize('Sorry, cashier is temporarily unavailable due to system maintenance.'),
        SystemMaintenanceCrypto           => localize('Sorry, crypto cashier is temporarily unavailable due to system maintenance.'),
        SystemMaintenanceDepositOutage    => localize('Deposits are temporarily unavailable for [_1]. Please try later.'),
        SystemMaintenanceWithdrawalOutage => localize('Withdrawals are temporarily unavailable for [_1]. Please try later.'),
        CurrencyNotApplicable             => localize('[_1] transactions may not be performed with this account.'),
        SetExistingAccountCurrency        => localize('Please set the currency.'),
        FinancialAssessmentRequired       => localize('Please complete the financial assessment form to lift your withdrawal and trading limits.'),
        FinancialRiskNotApproved          => localize('Financial Risk approval is required.'),
        CashierRequirementsMissing        => localize('Your profile appears to be incomplete. Please update your personal details to continue.'),
        NoUkgcFundsProtection             => localize('Please accept Funds Protection.'),
        NoWithdrawalOrTradingStatus       => localize('Your account is restricted to deposits only.'),
        WithdrawalLockedStatus            => localize('Your account is locked for withdrawals.'),
        HighRiskNotAuthenticated          => localize('Please authenticate your account.'),
        PotentialFraud                    => localize('Please authenticate your account.'),

        # Payment validation
        CurrencyMismatch           => localize("Payment currency [_1] not client currency [_2]."),    # test it!
        SelfExclusionLimitExceeded => localize(
            'This deposit will cause your account balance to exceed your limit of [_1] [_2]. To proceed with this deposit, please adjust your self exclusion settings.'
        ),
        BalanceExceeded      => localize('This deposit will cause your account balance to exceed your account limit of [_1] [_2].'),
        DepositLimitExceeded => localize('Deposit exceeds [_1] limit [_2]. Aggregated deposit over period [_3]. Current amount [_4].'),    # test it
        AmountExceedsBalance => localize('Withdrawal amount ~[[_1] [_2]~] exceeds client balance ~[[_3] [_2]~].'),
        AmountExceedsUnfrozenBalance => localize('Withdrawal is [_2] [_1] but balance [_3] includes frozen bonus [_4].'),
        InvalidAccount               => localize('Invalid account.'),
        InvalidLandingCompany        => localize('Invalid landing company - [_1]'),
        WithdrawalLimitReached       => localize(
            "You've reached the maximum withdrawal limit of [_1] [_2]. Please authenticate your account before proceeding with this withdrawal."),
        WithdrawalLimit => localize(
            "We're unable to process your withdrawal request because it exceeds the limit of [_1] [_2]. Please authenticate your account before proceeding with this withdrawal."
        ),

        # payment agent withdraw
        PaymentagentWithdrawalNotAllowed => localize('You are not authorized for withdrawals via payment agents.'),
        PASameAccountWithdrawal          => localize('You cannot withdraw funds to the same account.'),
        PaymentagentNotAuthenticated     =>
            localize("You cannot perform the withdrawal to account [_1], as the payment agent's account is not authorized."),
        PAWithdrawalDifferentBrokers   => localize('Payment agent withdrawals are not allowed for specified accounts.'),
        ClientInsufficientBalance      => localize('Sorry, you cannot withdraw. Your account balance is [_3] [_2].'),
        ClientCurrencyMismatchWithdraw => localize('You cannot perform this action, as [_1] is not default currency for your account [_2].'),
        PACurrencyMismatchWithdraw     => localize('You cannot perform this action, as [_1] is not default currency for payment agent account [_2].'),
        PADisabledAccountWithdraw      => localize("You cannot perform the withdrawal to account [_1], as the payment agent's account is disabled."),
        PAUnwelcomeStatusWithdraw      => localize("We cannot transfer to account [_1]. Please select another payment agent."),
        PACashierLockedWithdraw        => localize("You cannot perform the withdrawal to account [_1], as the payment agent's cashier is locked."),
        PADocumentsExpiredWithdraw     =>
            localize("You cannot perform withdrawal to account [_1], as payment agent's verification documents have expired."),
        PaymentAgentNotWithinLimits     => localize('Invalid amount. Minimum is [_1], maximum is [_2].'),
        PaymentAgentDailyAmountExceeded =>
            localize('Payment agent transfers are not allowed, as you have exceeded the maximum allowable transfer amount [_1] [_2] for today.'),
        PaymentAgentDailyCountExceeded =>
            localize('Payment agent transfers are not allowed, as you have exceeded the maximum allowable transactions for today.'),

        # payment agent transfer
        PermissionDenied          => 'Permission denied.',
        PaymentAgentsNotAllowed   => 'The payment agent facility is not available for this account.',
        RequirementsMissing       => 'Your profile appears to be incomplete. Please update your personal details to continue.',
        DifferentLandingCompanies => 'Payment agent transfers are not allowed for the specified accounts.',
        PACurrencyMismatch        => localize('You cannot perform this action, as [_1] is not the default account currency for payment agent [_2].'),
        ClientCurrencyMismatch    => localize('You cannot perform this action, as [_1] is not the default account currency for client [_2].'),
        ClientCashierLocked       => localize('You cannot transfer to account [_1], as their cashier is locked.'),
        ClientDisabledAccount     => localize('You cannot transfer to account [_1], as their account is disabled.'),
        ClientDocumentsExpired    => localize('You cannot transfer to account [_1], as their verification documents have expired.'),
        ClientRequirementsMissing => localize('You cannot transfer to account [_1], as their profile is incomplete.'),
        ClientsAreTheSame         => localize('Payment agent transfers are not allowed within the same account.'),
        NotAuthorized             => localize('Your account needs to be authenticated to perform payment agent transfers.'),
        PATransferClientFailure   => localize('You cannot transfer to account [_1]'),
        PaymentAgentNotWithinLimits => localize('Invalid amount. Minimum is [_1], maximum is [_2].'),

        P2PDepositsWithdrawal => localize('To withdraw more than [_1] [_3], please use Deriv P2P.'),
        P2PDepositsTransfer   => localize('The maximum you can transfer is [_1] [_3]. You can withdraw the balance ([_2] [_3]) through Deriv P2P.'),
        P2PDepositsWithdrawalZero => localize('Please use Deriv P2P to make a withdrawal.'),
        P2PDepositsTransferZero   => localize('Please use Deriv P2P to make a withdrawal. Transfers aren’t possible for your account at the moment.'),

        ServiceNotAllowedForPA => localize('This service is not available for payment agents.'),
        TransferToOtherPA      => localize('You are not allowed to transfer to other payment agents.'),
        TransferToNonPaSibling => localize('You are not allowed to transfer to this account.'),
        ExperimentalCurrency   => localize("This currency is temporarily suspended. Please select another currency to proceed."),

        # Crypto withdrawal
        CryptoMissingRequiredParameter  => localize('Missing required parameter.'),
        CryptoWithdrawalBalanceExceeded => localize('Withdrawal amount of [_1] [_2] exceeds your account balance of [_3] [_2].'),
        CryptoWithdrawalError           => localize('Error validating your transaction, please try again in a few minutes.'),
        CryptoWithdrawalLimitExceeded   => localize('Withdrawal amount of [_1] [_2] exceeds your account withdrawal limit of [_3] [_2].'),
        CryptoWithdrawalMaxReached      =>
            localize('You have reached the maximum withdrawal limit of [_1] [_2]. Please authenticate your account to make unlimited withdrawals.'),
        CryptoWithdrawalNotAuthenticated => localize('Please authenticate your account to proceed with withdrawals.'),
    };
}

=head2 is_idv_disabled

Checks if IDV has been dynamically disabled.

=over 4

=item C<args>: hash containing country and provider

=back

Returns bool

=cut

sub is_idv_disabled {
    my %args = @_;
    # Is IDV disabled
    return 1 if BOM::Config::Runtime->instance->app_config->system->suspend->idv;
    # Is IDV country disabled
    my $disabled_idv_countries = BOM::Config::Runtime->instance->app_config->system->suspend->idv_countries;
    if (defined $args{country}) {
        return 1 if any { $args{country} eq $_ } @$disabled_idv_countries;
    }
    # Is IDV provider disabled
    my $disabled_idv_providers = BOM::Config::Runtime->instance->app_config->system->suspend->idv_providers;
    if (defined $args{provider}) {
        return 1 if any { $args{provider} eq $_ } @$disabled_idv_providers;
    }
    return 0;
}

=head2 has_idv

Checks if IDV is enabled and supported for the given country + provider

=over 4

=item C<args>: hash containing country and provider

=back

Returns bool

=cut

sub has_idv {
    my %args            = @_;
    my $country_configs = Brands::Countries->new();
    return 0 unless $country_configs->is_idv_supported($args{country} // '');

    return 0 if is_idv_disabled(%args);

    return 1;
}

=head2 rejected_onfido_reasons

return a hashref about strings of recjected onfido reasons

=cut

sub rejected_onfido_reasons {
    ## no critic(TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'redefine';
    local *localize = sub { die 'you probably wanted an arrayref for this localize() call' if @_ > 1; shift };
    return {
        'data_comparison.first_name'                    => localize("The name on your document doesn't match your profile."),
        'data_comparison.last_name'                     => localize("The name on your document doesn't match your profile."),
        'data_comparison.date_of_birth'                 => localize("The date of birth on your document doesn't match your profile."),
        'data_comparison.date_of_expiry'                => localize("Your document has expired."),
        'data_comparison.issuing_country'               => localize("Your document appears to be invalid."),
        'data_comparison.document_type'                 => localize("Your document appears to be invalid."),
        'data_comparison.document_numbers'              => localize("Your document appears to be invalid."),
        'visual_authenticity.original_document_present' =>
            localize("Your document appears to be a scanned copy that contains markings or text that shouldn't be on your document."),
        'visual_authenticity.original_document_present.scan' => localize(
            "We're unable to verify the document you provided because it contains markings or text that should not be on your document. Please provide a clear photo or a scan of your original identity document."
        ),
        'visual_authenticity.original_document_present.document_on_printed_paper' => localize("Your document appears to be a printed copy."),
        'visual_authenticity.original_document_present.screenshot'                => localize("Your document appears to be a screenshot."),
        'visual_authenticity.original_document_present.photo_of_screen' => localize("Your document appears to be a photo of a device screen."),
        'visual_authenticity.fonts'                                     => localize("Your document appears to be invalid."),
        'visual_authenticity.face_detection'                            => localize("Your document appears to be invalid."),
        'visual_authenticity.security_features'                         => localize("Your document appears to be invalid."),
        'visual_authenticity.template'                                  => localize("Your document appears to be invalid."),
        'visual_authenticity.digital_tampering'                         => localize("Your document appears to be invalid."),
        'visual_authenticity.picture_face_integrity'                    => localize("Your document appears to be invalid."),
        'data_validation.date_of_birth'               => localize("Some details on your document appear to be invalid, missing, or unclear."),
        'data_validation.document_expiration'         => localize("Your document has expired."),
        'data_validation.document_numbers'            => localize("Some details in your document appear to be invalid, missing, or unclear."),
        'data_validation.no_document_numbers'         => localize("The serial number of your document couldn't be verified."),
        'data_validation.expiry_date'                 => localize("Some details on your document appear to be invalid, missing, or unclear."),
        'data_validation.mrz'                         => localize("Some details on your document appear to be invalid, missing, or unclear."),
        'image_integrity.conclusive_document_quality' => localize("Your document appears to be invalid."),
        'image_integrity.conclusive_document_quality.missing_back' =>
            localize("The back of your document appears to be missing. Please include both sides of your identity document."),
        'image_integrity.conclusive_document_quality.digital_document'                => localize("Your document appears to be a digital document."),
        'image_integrity.conclusive_document_quality.punctured_document'              => localize("Your document appears to be damaged or cropped."),
        'image_integrity.conclusive_document_quality.corner_removed'                  => localize("Your document appears to be damaged or cropped."),
        'image_integrity.conclusive_document_quality.watermarks_digital_text_overlay' =>
            localize("Your document contains markings or text that should not be on your document."),
        'image_integrity.conclusive_document_quality.abnormal_document_features' =>
            localize("Some details on your document appear to be invalid, missing, or unclear."),
        'image_integrity.conclusive_document_quality.obscured_security_features' =>
            localize("Some details on your document appear to be invalid, missing, or unclear."),
        'image_integrity.conclusive_document_quality.obscured_data_points' =>
            localize("Some details on your document appear to be invalid, missing, or unclear."),
        'image_integrity.colour_picture' =>
            localize("Your document appears to be in black and white. Please upload a colour photo of your document."),
        'image_integrity.supported_document' =>
            localize("The document you provided is not supported for your country. Please provide a supported document for your country."),
        'image_integrity.image_quality' =>
            localize("The image quality of your document is too low. Please provide a hi-res photo of your identity document."),
        'image_integrity.image_quality.dark_photo' => localize(
            "We were unable to verify your selfie because it's not clear. Please take a clearer photo and try again. Ensure that there's enough light where you are and that your entire face is in the frame."
        ),
        'image_integrity.image_quality.glare_on_photo' => localize(
            "We were unable to verify your selfie because it's not clear. Please take a clearer photo and try again. Ensure that there's enough light where you are and that your entire face is in the frame."
        ),
        'image_integrity.image_quality.blurred_photo' => localize(
            "We were unable to verify your selfie because it's not clear. Please take a clearer photo and try again. Ensure that there's enough light where you are and that your entire face is in the frame."
        ),
        'image_integrity.image_quality.covered_photo' => localize(
            "We're unable to verify the document you provided because some details appear to be missing. Please try again or provide another document."
        ),
        'image_integrity.image_quality.other_photo_issue' => localize(
            "We're unable to verify the document you provided because some details appear to be missing. Please try again or provide another document."
        ),
        'image_integrity.image_quality.damaged_document' => localize(
            "We're unable to verify the document you provided because it appears to be damaged. Please try again or upload another document."),
        'image_integrity.image_quality.incorrect_side' =>
            localize("The front of your document appears to be missing. Please provide both sides of your identity document."),
        'image_integrity.image_quality.cut_off_document' => localize(
            "We're unable to verify the document you provided because it appears to be damaged. Please try again or upload another document."),
        'image_integrity.image_quality.no_document_in_image' => localize(
            "We're unable to verify the document you provided because it appears to be a blank image. Please try again or upload another document."),
        'image_integrity.image_quality.two_documents_uploaded' =>
            localize("The document you provided appears to be two different types. Please try again or provide another document."),
        'compromised_document'                => localize("Your document failed our verification checks."),
        'age_validation.minimum_accepted_age' => localize(
            "Your age in the document you provided appears to be below 18 years. We're only allowed to offer our services to clients above 18 years old, so we'll need to close your account. If you have a balance in your account, contact us via live chat and we'll help to withdraw your funds before your account is closed."
        ),
        'selfie' => localize(
            "Your selfie isn't clear. Please take a clearer photo and try again. Ensure that there's enough light where you are and that your entire face is in the frame."
        ),
    };

}

=head2 rejected_identity_verification_reasons

return a hashref about strings of recjected identity verificationreasons

=cut

sub rejected_identity_verification_reasons {
    ## no critic(TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'redefine';
    local *localize = sub { die 'you probably wanted an arrayref for this localize() call' if @_ > 1; shift };
    return {
        'UNDERAGE'           => localize("You're under legal age."),
        'NAME_MISMATCH'      => localize("The name retrieved from your document doesn't match your profile."),
        'DOB_MISMATCH'       => localize("The date of birth retrieved from your document doesn't match your profile."),
        'EMPTY_STATUS'       => localize("The verification status was empty, rejected for lack of information."),
        'INFORMATION_LACK'   => localize("The verfication is passed but the personal info is not available to compare."),
        'DOCUMENT_REJECTED'  => localize("Document was rejected by the provider."),
        'UNAVAILABLE_STATUS' => localize("The verification status is not available, provider says: N/A."),
        'UNAVAILABLE_ISSUER' => localize("The verification status is not available, provider says: Issuer Unavailable."),
        'EXPIRED'            => localize("The document's validity has been expired."),
    };
}

=head2 create_error

Creates the standard error structure.

Takes the following parameters:

=over 4

=item * C<$error_code> - A key from C<error_map> hash as string

=item * C<%options> - List of possible options to be used in creating the error, containing the following keys:

=over 4

=item * C<message_params> - List of values for placeholders to pass to C<localize()>, should be arrayref if more than one value

=item * C<details> - Hashref containing the details about this error in case C<details> provided in <options> parameter

=back

=back

Returns error as hashref containing the following keys:

=over 4

=item * C<code> - The error code from C<error_map>

=item * C<message> - The localized error message

=item * C<details> - Hashref containing the exact C<details> passed in <options> parameter

=back

=cut

sub create_error {
    my ($error_code, %options) = @_;

    my $message = error_map->{$error_code} || error_map->{UnknownError};

    my @params;
    if (my $message_params = $options{message_params}) {
        @params = ref $message_params eq 'ARRAY' ? $message_params->@* : ($message_params);
    }

    $message = localize($message, @params);

    return {
        error => {
            code              => $error_code,
            message_to_client => $message,
            $options{details} ? (details => $options{details}) : (),
        }};
}

1;
