package BOM::Platform::Utility;

use strict;
use warnings;

use Clone::PP  qw(clone);
use List::Util qw(any uniq);
use Syntax::Keyword::Try;
use Brands::Countries;

use BOM::Platform::Context qw(request localize);
use BOM::Config::Runtime;
use BOM::User::Client;

use base qw( Exporter );
our @EXPORT_OK = qw(error_map create_error verify_reactivation);

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
        AppropriatenessTestFailed         => localize('Failed to reach an acceptable trading experience score.'),
        CashierNotAllowed                 => localize('Cashier deposits and withdrawals are not allowed on this account.'),

        # Payment validation
        CurrencyMismatch           => localize("Payment currency [_1] not client currency [_2]."),    # test it!
        SelfExclusionLimitExceeded => localize(
            'This deposit will cause your account balance to exceed your limit of [_1] [_2]. To proceed with this deposit, please adjust your self exclusion settings.'
        ),
        BalanceExceeded      => localize('This deposit will cause your account balance to exceed your account limit of [_1] [_2].'),
        DepositLimitExceeded => localize('Deposit exceeds [_1] limit [_2]. Aggregated deposit over period [_3]. Current amount [_4].'),    # test it
        AmountExceedsBalance => localize('Withdrawal amount ~[[_1] [_2]~] exceeds client balance ~[[_3] [_2]~].'),
        AmountExceedsUnfrozenBalance => localize('Withdrawal is [_2] [_1] but balance [_3] includes frozen bonus [_4].'),
        NoBalance                    => localize('This transaction cannot be done because your [_1] account has zero balance.'),
        NoBalanceVerifyMail          => localize("Withdrawal isn't possible because you have no funds in your [_1] account."),
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
        PaymentAgentWithdrawSameMethod => localize("To continue withdrawals, please select the same payment method you used to deposit."),
        PaymentAgentJustification      => localize(
            "It seems you've not taken full advantage of our trading facilities with the deposit you've made. Before we can enable you to make a withdrawal via a payment agent, we need you to contact us by live chat to explain why you wish to withdraw funds."
        ),
        PaymentAgentJustificationAdded => localize(
            "We're processing your request to withdraw funds via a payment agent. You'll get to know the status of your request via email within 24 hours."
        ),
        PaymentAgentUseOtherMethod => localize(
            "Please use an e-wallet that you have used for deposits previously or create a new e-wallet if you don't have one. Ensure the e-wallet supports withdrawal. See the list of e-wallets that support withdrawals here: https://deriv.com/payment-methods"
        ),
        PaymentAgentZeroDeposits  => localize("Withdrawals are not possible because there are no funds in this account yet."),
        PaymentAgentVirtualClient => localize("Withdrawals are not possible on your demo account. You can only withdraw from a real account."),

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
        P2PDepositsTransferZero   => localize("Please use Deriv P2P to make a withdrawal. Transfers aren't possible for your account at the moment."),

        ServiceNotAllowedForPA     => localize('This service is not available for payment agents.'),
        TransferToOtherPA          => localize('You are not allowed to transfer to other payment agents.'),
        TransferToNonPaSibling     => localize('You are not allowed to transfer to this account.'),
        PACommisionWithdrawalLimit => localize('The amount you entered exceeds your commission balance. You may withdraw up to [_1] [_2].'),
        ExperimentalCurrency       => localize("This currency is temporarily suspended. Please select another currency to proceed."),

        # Crypto withdrawal
        CryptoMissingRequiredParameter  => localize('Missing required parameter.'),
        CryptoWithdrawalBalanceExceeded => localize('Withdrawal amount of [_1] [_2] exceeds your account balance of [_3] [_2].'),
        CryptoWithdrawalError           => localize('Error validating your transaction, please try again in a few minutes.'),
        CryptoWithdrawalLimitExceeded   => localize('Withdrawal amount of [_1] [_2] exceeds your account withdrawal limit of [_3] [_2].'),
        CryptoLimitAgeVerified          => localize(
            'Withdrawal request of [_1] [_2] exceeds cumulative limit for transactions. To continue, you will need to verify your identity.'),
        CryptoWithdrawalMaxReached =>
            localize('You have reached the maximum withdrawal limit of [_1] [_2]. Please authenticate your account to make unlimited withdrawals.'),
        CryptoWithdrawalNotAuthenticated => localize('Please authenticate your account to proceed with withdrawals.'),
        InternalClient                   => localize('This feature is not allowed for internal clients.'),
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

    my $disabled_idv_countries = BOM::Config::Runtime->instance->app_config->system->suspend->idv_countries;
    my $disabled_idv_providers = BOM::Config::Runtime->instance->app_config->system->suspend->idv_providers;
    my $disabled_idv_documents = BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types;

    # Is IDV country disabled
    if (defined $args{country}) {
        return 1 if any { $args{country} eq $_ } @$disabled_idv_countries;

        my $brand_countries_obj = Brands::Countries->new;
        my $document_types      = $brand_countries_obj->get_idv_config($args{country})->{document_types};

        my $disabled_documents = 0;
        for my $document_type (keys $document_types->%*) {
            if (any { $args{country} . ':' . $document_type eq $_ } @$disabled_idv_documents) {
                $disabled_documents++;
            }
        }
        return 1 if scalar keys $document_types->%* == $disabled_documents;
    }
    # Is IDV provider disabled
    if (defined $args{provider}) {
        return 1 if any { $args{provider} eq $_ } @$disabled_idv_providers;
    }
    # Is IDV document type disabled for the specific country
    if (defined $args{country} and defined $args{document_type}) {
        return 1 if any { $args{country} . ':' . $args{document_type} eq $_ } @$disabled_idv_documents;
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
            "We're unable to verify the selfie you provided as it does not match the required criteria. Please provide a photo that closely resembles the document photo provided."
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
        'UNDERAGE'                      => localize("You're under legal age."),
        'NAME_MISMATCH'                 => localize("The name retrieved from your document doesn't match your profile."),
        'DOB_MISMATCH'                  => localize("The date of birth retrieved from your document doesn't match your profile."),
        'EMPTY_STATUS'                  => localize("The verification status was empty, rejected for lack of information."),
        'INFORMATION_LACK'              => localize("The verification is passed but the personal info is not available to compare."),
        'DOCUMENT_REJECTED'             => localize("Document was rejected by the provider."),
        'UNAVAILABLE_STATUS'            => localize("The verification status is not available, provider says: N/A."),
        'UNAVAILABLE_ISSUER'            => localize("The verification status is not available, provider says: Issuer Unavailable."),
        'EXPIRED'                       => localize("The document's validity has been expired."),
        'PROVIDER_UNAVAILABLE'          => localize("The verification status is not available, provider says: Provider Unavailable."),
        'REJECTED_BY_PROVIDER'          => localize("The document was rejected by the Provider."),
        'MALFORMED_JSON'                => localize("The verification status is not available, provider says: Malformed JSON."),
        'VERIFICATION_STARTED'          => localize("The document's verification has started."),
        'UNEXPECTED_ERROR'              => localize("The verification status is not available, provider says: Unexpected Error."),
        'UNDESIRED_HTTP_CODE'           => localize("The verification status is not available, provider says: Undesired HTTP code."),
        'TIMEOUT'                       => localize("The verification status is not available, provider says: Timeout."),
        'NEEDS_TECHNICAL_INVESTIGATION' => localize("The verification status is not available, provider says: Needs Technical Investigation."),
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

    my $message = error_map()->{$error_code} || error_map()->{UnknownError};

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

=head2 status_op_processor

Given an input and a client, this sub will process the given statuses expecting multiple
statuses passed.

It takes the following arguments:

=over 4

=item * C<client> - the client instance

=item * C<input> - a hashref of the user inputs

=back

The input should have a B<status_op> key that may contain:

=over 4

=item * C<remove> - this op performs a status removal from the client

=item * C<remove_siblings> - the same as `remove` but will also remove the status from siblings

=item * C<sync> - this op copies the given statuses to the siblings

=back

From the input hashref we will look for a `status_checked` value that can either be an arrayref or string (must check for that).
This value represents the given status codes.

Returns a summary to print out or undef if nothing happened.

=cut

sub status_op_processor {
    my ($client, $args) = @_;
    my $status_op      = $args->{status_op};
    my $status_checked = $args->{status_checked} // [];
    $status_checked = [$status_checked] unless ref($status_checked);
    my $client_status_type = $args->{untrusted_action_type};
    my $reason             = $args->{reason};
    my $clerk              = $args->{clerk};
    my $status_map         = {
        disabledlogins            => 'disabled',
        lockcashierlogins         => 'cashier_locked',
        unwelcomelogins           => 'unwelcome',
        nowithdrawalortrading     => 'no_withdrawal_or_trading',
        lockwithdrawal            => 'withdrawal_locked',
        lockmt5withdrawal         => 'mt5_withdrawal_locked',
        duplicateaccount          => 'duplicate_account',
        allowdocumentupload       => 'allow_document_upload',
        internalclient            => 'internal_client',
        notrading                 => 'no_trading',
        sharedpaymentmethod       => 'shared_payment_method',
        cryptoautorejectdisabled  => 'crypto_auto_reject_disabled',
        cryptoautoapprovedisabled => 'crypto_auto_approve_disabled',
    };

    if ($client_status_type && $status_map->{$client_status_type}) {
        push(@$status_checked, $client_status_type);
    }
    @$status_checked = uniq @$status_checked;
    return undef unless $status_op;
    return undef unless scalar $status_checked->@*;

    my $loginid       = $client->loginid;
    my $summary_stack = [];
    my $old_db        = $client->get_db();
    # assign write access to db_operation to perform client_status delete/copy operation
    $client->set_db('write') if 'write' ne $old_db;

    for my $status ($status_checked->@*) {
        try {
            if ($status_op eq 'remove') {
                verify_reactivation($client, $status);
                my $client_status_clearer_method_name = 'clear_' . $status;
                $client->status->$client_status_clearer_method_name;
                push $summary_stack->@*,
                    {
                    status => $status,
                    passed => 1,
                    ids    => $loginid
                    };
            } elsif ($status_op eq 'remove_siblings' or $status_op eq 'remove_accounts') {

                my ($updated, $failed) = clear_status_from_siblings($client, $status, $status_op eq 'remove_accounts');
                if (scalar @$updated) {
                    my $siblings = join ', ', map { $_->{loginid} } @$updated;
                    push $summary_stack->@*,
                        {
                        status => $status,
                        passed => 1,
                        ids    => $siblings,
                        };
                }

                if (scalar @$failed) {
                    my $failed_errors   = join ', ', map { $_->{error} } @$failed;
                    my $failed_siblings = join ', ', map { $_->{loginid} } @$failed;
                    push $summary_stack->@*,
                        {
                        status => $status,
                        passed => 0,
                        ids    => $failed_siblings,
                        errors => $failed_errors
                        };
                }

            } elsif ($status_op eq 'sync' or $status_op eq 'sync_accounts') {
                $status = $status_map->{$status}       ? $status_map->{$status}           : $status;
                $reason = $reason =~ /SELECT A REASON/ ? $client->status->reason($status) : $reason;
                my $updated_client_loginids = $client->copy_status_to_siblings($status, $clerk, $status_op eq 'sync_accounts', $reason);
                my $siblings = join ', ', $updated_client_loginids->@*;
                if (scalar $updated_client_loginids->@*) {
                    push $summary_stack->@*,
                        {
                        status => $status,
                        passed => 1,
                        ids    => $siblings
                        };
                }
            }
        } catch ($e) {
            push $summary_stack->@*,
                {
                status => $status,
                passed => 0,
                ids    => $loginid,
                error  => $e,
                };
        }
    }
    # once db operation is done, set back db_operation to replica
    $client->set_db($old_db) if 'write' ne $old_db;
    return $summary_stack;
}

=head2 clear_status_from_siblings

Clear the speciefied from account siblings

=over 4

=item * C<client> - the client instance

=item * C<status> - a hashref of the user inputs

=item * C<remove_accounts> - specifies whether we should remove accounts within same landing company or all landing companie wit virtuals

=back

Returns array ref of success and failed accounts

=over 4

=item * C<successed> - array ref of successful removals

=item * C<failed> - array ref of failed removals

=back

=cut

sub clear_status_from_siblings {
    my ($client, $status, $remove_accounts) = @_;

    my $sub_name = "clear_$status";
    my (@successed, @failed);
    my @siblings =
          $remove_accounts
        ? $client->user->clients(include_disabled => 1)
        : $client->user->clients_for_landing_company($client->landing_company->short);
    push @siblings, $client if ($remove_accounts);
    for my $sibling (@siblings) {
        try {
            verify_reactivation($sibling, $status);
            $sibling->status->$sub_name;
            push @successed, $sibling;
        } catch ($e) {
            my %fail = (
                loginid => $sibling->{loginid},
                error   => $e
            );
            push @failed, \%fail;
        }

    }
    return (\@successed, \@failed);
}

=head2 verify_reactivation

verify the reactivation of an account, which means the removal of the disabled or duplicate_account

=over 4

=item * C<client> - the client instance

=item * C<status> - the client status to be cleared

=back

It return either an error or a 1 which means success

=cut

sub verify_reactivation {
    my ($client, $status) = @_;

    return 0 unless ($status eq 'disabled'     or $status eq 'duplicate_account');
    return 0 unless ($client->status->disabled or $client->status->duplicate_account);

    my @required_args = qw(loginid currency date_of_birth place_of_birth citizen residence
        promo_code_status promo_code non_pep_declaration_time address_line_1 address_line_2 address_postcode);

    try {
        my $rule_engine     = BOM::Rules::Engine->new(client => $client);
        my $landing_company = $client->landing_company->short;
        my $market_type;
        if ($landing_company eq 'maltainvest') {
            $market_type = 'financial';
        } else {
            my $countries_instance = request()->brand->countries_instance;
            my $company            = $countries_instance->gaming_company_for_country($client->residence);
            $market_type = $company ? 'financial' : 'synthetic';
        }

        my $account_type = $client->get_account_type;
        my $action       = $account_type->category->name eq 'wallet' ? 'activate_wallet' : 'activate_account';

        $rule_engine->verify_action(
            $action,
            action_type     => 'reactivate',
            account_type    => $client->get_account_type->name,
            market_type     => $market_type,
            landing_company => $landing_company,
            (map { $_ => $client->$_ } @required_args),
            promo_code_status => undef,

        );
    } catch ($e) {
        my $error        = ref($e) ? $e->{error_code} // '' : $e;
        my $failing_rule = $e->{rule};
        $error =~ s/([A-Z])/ $1/g;
        die {
            error_msg    => $error,
            failing_rule => $failing_rule
        };
    };

    return 1;
}

=head2 get_fiat_sibling_account_currency_for

finds & returns fiat sibling currency code

=over 4

=item C<loginid>: client loginid

=back

Returns fiat_currency if fiat sibling account exists

=cut

sub get_fiat_sibling_account_currency_for {
    my ($loginid) = @_;
    my $client = BOM::User::Client->new({loginid => $loginid});
    my $fiat_currency;
    foreach my $login_id ($client->user->bom_real_loginids) {
        my $client_account = BOM::User::Client->new({loginid => $login_id});
        next unless $client_account->currency;
        next if (LandingCompany::Registry::get_currency_type($client_account->currency) // '') eq 'crypto';
        $fiat_currency = $client_account->account->currency_code;
        last;
    }
    return $fiat_currency;
}
1;
