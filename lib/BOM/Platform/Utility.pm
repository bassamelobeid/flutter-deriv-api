package BOM::Platform::Utility;

use strict;
use warnings;

use Clone::PP qw(clone);
use List::Util qw(any);
use Brands::Countries;

use BOM::Platform::Context qw/localize/;
use BOM::Config::Runtime;

use base qw( Exporter );
our @EXPORT_OK = qw(error_map);

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
        virtual_account => localize('This is a virtual-money account. Please switch to a real-money account to access cashier.'),
        NoResidence     => localize('Please set your country of residence.'),
        CashierLocked   => localize('Your cashier is locked.'),
        DisabledAccount => localize('Your account is disabled.'),

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

        InternalCashierError        => localize('Sorry, cashier is temporarily unavailable. Please try again later.'),
        system_maintenance          => localize('Sorry, cashier is temporarily unavailable due to system maintenance.'),
        system_maintenance_crypto   => localize('Sorry, crypto cashier is temporarily unavailable due to system maintenance.'),
        CurrencyNotApplicable       => localize('[_1] transactions may not be performed with this account.'),
        SetExistingAccountCurrency  => localize('Please set the currency.'),
        FinancialAssessmentRequired => localize('Please complete the financial assessment form to lift your withdrawal and trading limits.'),
        FinancialRiskNotApproved    => localize('Financial Risk approval is required.'),
        CashierRequirementsMissing  => localize('Your profile appears to be incomplete. Please update your personal details to continue.'),
        NoUkgcFundsProtection       => localize('Please accept Funds Protection.'),
        NoWithdrawalOrTradingStatus => localize('Your account is restricted to deposits only.'),
        WithdrawalLockedStatus      => localize('Your account is locked for withdrawals.'),
        HighRiskNotAuthenticated    => localize('Please authenticate your account.'),
        PotentialFraud              => localize('Please authenticate your account.'),

        # Payment validation
        CurrencyMismatch           => localize("Payment currency [_1] not client currency [_2]."),    # test it!
        SelfExclusionLimitExceeded => localize(
            'This deposit will cause your account balance to exceed your limit of [_1] [_2]. To proceed with this deposit, please adjust your self exclusion settings.'
        ),
        BalanceExceeded      => localize('This deposit will cause your account balance to exceed your account limit of [_1] [_2].'),
        DepositLimitExceeded => localize('Deposit exceeds [_1] limit [_2]. Aggregated deposit over period [_3]. Current amount [_4].'),    # test it
        AmountExceedsBalance => localize('Withdrawal amount ~[[_1] [_2]~] exceeds client balance ~[[_3] [_2]~].'),
        AmountExceedsUnfrozenBalance => localize('Withdrawal is [_2] [_1] but balance [_3] includes frozen bonus [_4].'),
        InvalidLandingCompany        => localize('Invalid landing company - [_1]'),
        WithdrawalLimitReached       => localize(
            "You've reached the maximum withdrawal limit of [_1] [_2]. Please authenticate your account before proceeding with this withdrawal."),
        WithdrawalLimit => localize(
            "We're unable to process your withdrawal request because it exceeds the limit of [_1] [_2]. Please authenticate your account before proceeding with this withdrawal."
        ),

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

1;
