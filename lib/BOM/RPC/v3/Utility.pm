
=head1 BOM::RPC::v3::Utility

Utility package for BOM::RPC::v3

=cut

package BOM::RPC::v3::Utility;

use strict;
use warnings;

use utf8;

no indirect;

use Syntax::Keyword::Try;
use Date::Utility;
use YAML::XS      qw(LoadFile);
use List::Util    qw( any  uniqstr  shuffle  minstr  none  first);
use List::UtilsBy qw(bundle_by);
use JSON::MaybeXS qw{encode_json};
use URI;
use Domain::PublicSuffix;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc stats_gauge);
use Time::HiRes;
use Time::Duration::Concise::Localize;
use Format::Util::Numbers qw/formatnumber/;
use JSON::MaybeUTF8       qw/encode_json_utf8 decode_json_utf8/;

use Quant::Framework;
use LandingCompany::Registry;
use Finance::Contract::Longcode qw(shortcode_to_longcode);
use Finance::Underlying;

use BOM::Platform::Context        qw(localize request);
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Config::CurrencyConfig;
use BOM::Config::Redis;
use BOM::Config::Runtime;
use BOM::Platform::Token::API;
use BOM::Database::Model::OAuth;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Token::API;
use BOM::Platform::Token;
use BOM::Platform::Email qw(send_email);
use BOM::MarketData      qw(create_underlying);
use BOM::Platform::Event::Emitter;
use BOM::Platform::Client::CashierValidation;
use BOM::Platform::Utility;
use BOM::User;
use BOM::Transaction::Validation;
use BOM::Config;
use BOM::Rules::Engine;
use BOM::TradingPlatform;
use Time::Moment;
use Exporter qw(import export_to_level);
our @EXPORT_OK = qw(longcode log_exception get_verification_uri get_app_name request_email aggregate_ticks_history_metrics);

use feature "state";

# Number of keys to get/set per batch in Redis
use constant LONGCODE_REDIS_BATCH => 20;

# Seconds between reloads of the rate_limitations.yml file.
# We don't want to reload too frequently, since we may see a lot of `website_status` calls.
# However, it's a config file held outside the repo, so we also don't want to let it get too old.
use constant RATES_FILE_CACHE_TIME => 120;

# For transfers, defines the oldest rates allowed for currency conversion per currency type
use constant CURRENCY_CONVERSION_MAX_AGE_FIAT   => 3600 * 24;             # 1 day
use constant CURRENCY_CONVERSION_MAX_AGE_CRYPTO => 3600;
use constant GENERIC_DD_STATS_KEY               => 'bom.rpc.exception';

# A regular expression for validate all kind of passwords
# the regex checks password is:
# - between 8 and 25 characters
# - includes at least 1 character of numbers and alphabet (both lower and uppercase)
# - all characters ASCII index should be within ( )[space] to (~)[tilde] indexes range
use constant REGEX_PASSWORD_VALIDATION => qr/^(?=.*[a-z])(?=.*[0-9])(?=.*[A-Z])[ -~]{8,25}$/;

use constant REGEX_TRADING_PLATFORM_PASSWORD_VALIDATION => qr/^(?=.*[a-z])(?=.*[0-9])(?=.*[A-Z])[ -~]{8,25}$/;

use constant REGEX_TRADING_PLATFORM_PASSWORD_VALIDATION_MT5 =>
    qr/^(?=.*[a-z])(?=.*[0-9])(?=.*[A-Z])(?=.*[\!\@#\$%\^&\*\(\)\+\-\=\[\]\{\};\':\"\|\,\.<>\?_~])[ -~]{8,16}$/;

use constant {
    MAX_PASSWORD_CHECK_ATTEMPTS               => 5,
    CRYPTO_CONFIG_REDIS_CLIENT_MIN_AMOUNT     => "rpc::cryptocurrency::crypto_config::client_min_amount::",
    CRYPTO_CONFIG_REDIS_CLIENT_MIN_AMOUNT_TTL => 120,
};

=head2 validation_checks

Performs a list of given Transaction Validation checks for a given client.
Returns an error if a check fails else undef.

=cut

sub validation_checks {
    my ($client, $validations) = @_;

    $validations //= $client->landing_company->client_validation_misc;

    for my $act (@$validations) {
        die "Error: no such hook $act"
            unless BOM::Transaction::Validation->can($act);

        my $err;
        try {
            $err = BOM::Transaction::Validation->new({clients => [{client => $client}]})->$act($client);
        } catch {
            warn "Error happened when call before_action $act";
            $err = Error::Base->cuss({
                -type              => 'Internal Error',
                -mesg              => 'Internal Error',
                -message_to_client => localize('Sorry, there is an internal error.'),
            });
        }

        return BOM::RPC::v3::Utility::create_error({
                code              => $err->get_type,
                message_to_client => $err->{-message_to_client},
            }) if defined $err and ref $err eq "Error::Base";
    }

    return undef;
}

=head2 create_error

Description: Creates an error data structure that allows front-end to display the correct information

example

            return BOM::RPC::v3::Utility::create_error({
                    code              => 'ASK_FIX_DETAILS',
                    message           => 'There was a failure validatin gperson details'
                    message_to_client => localize('There was a problem validating your personal details.'),
                    details           => {fields => \@error_fields}});

Takes the following arguments as named parameters

=over 4

=item - code:  A short string acting as a key for this error.

=item - message_to_client: A string that will be shown to the end user.
This will nearly always need to be translated using the C<localize()> method.

=item - message: (optional)  Message to be written to the logs. Only log messages that can be
acted on.

=item - details: (optional) An arrayref with meta data for the error.  Has the following
optional attribute(s)

=over 4

=item - fields:  an arrayref of fields affected by this error. This allows frontend
to display appropriate warnings.

=back

=back

Returns a hashref

        {
        error => {
            code              => "Error Code",
            message_to_client => "Message to client",
            message, => "message that will be logged",
            details => HashRef of metadata to send to frontend
        }

=cut

sub create_error {
    my $args = shift;

    return {
        error => {
            code              => $args->{code},
            message_to_client => $args->{message_to_client},
            $args->{message} ? (message => $args->{message}) : (),
            $args->{details} ? (details => $args->{details}) : ()}};
}

sub invalid_token_error {
    return create_error({
            code              => 'InvalidToken',
            message_to_client => localize('The token is invalid.')});
}

sub permission_error {
    #use Carp; warn Carp::cluck("PERMISSION ERROR");
    return create_error({
            code              => 'PermissionDenied',
            message_to_client => localize('Permission denied.')});
}

sub rate_limit_error {
    return create_error({
            code              => 'RateLimitExceeded',
            message_to_client => localize('Rate Limit Exceeded.')});
}

sub invalid_email {
    return create_error({
            code              => 'InvalidEmail',
            message_to_client => localize('This email address is invalid.')});
}

sub suspended_login {
    return create_error({
            code              => 'Suspendedlogin',
            message_to_client => localize('We can\'t take you to your account right now due to system maintenance. Please try again later.')});
}

=head2 invalid_params

Validates the url_parameters.

- pa parameters are allowed only when the type provided is paymentagent_withdraw.

=over 4

=item * C<args> rpc params args

=back

Returns error if args are invalid, otherwise return undef

=cut

sub invalid_params {
    my $args = shift;

    my ($type, $url_parameters) = @{$args}{qw/type url_parameters/};

    return create_error({
            code              => 'InvalidParameters',
            message_to_client => 'pa parameters are valid from paymentagent_withdraw only'
        }) if grep { /^pa/ } keys $url_parameters->%* and $type ne 'paymentagent_withdraw';

    return undef;
}

# Start this at zero to ensure we always load on first call.
my $rates_file_last_load = 0;
my $rates_file_content;

sub site_limits {
    my $now = time;
    if ($now - $rates_file_last_load > RATES_FILE_CACHE_TIME) {
        $rates_file_content   = LoadFile($ENV{BOM_TEST_RATE_LIMITATIONS} // '/etc/rmg/perl_rate_limitations.yml');
        $rates_file_last_load = $now;
    }

    my $limits;
    $limits->{max_proposal_subscription} = {
        'applies_to' => 'subscribing to proposal concurrently',
        'max'        => 5
    };
    $limits->{'max_requestes_general'} = {
        'applies_to' => 'rest of calls',
        'minutely'   => $rates_file_content->{websocket_call}->{'1m'},
        'hourly'     => $rates_file_content->{websocket_call}->{'1h'}};
    $limits->{'max_requests_outcome'} = {
        'applies_to' => 'portfolio, statement and proposal',
        'minutely'   => $rates_file_content->{websocket_call_expensive}->{'1m'},
        'hourly'     => $rates_file_content->{websocket_call_expensive}->{'1h'}};
    $limits->{'max_requests_pricing'} = {
        'applies_to' => 'proposal and proposal_open_contract',
        'minutely'   => $rates_file_content->{websocket_call_pricing}->{'1m'},
        'hourly'     => $rates_file_content->{websocket_call_pricing}->{'1h'}};
    return $limits;
}

sub client_error () {
    return create_error({
            code              => 'InternalServerError',
            message_to_client => localize('Sorry, an error occurred while processing your request.')});
}

=head2 website_name

accepts server name & depending on production/qa environment returns website url

=over 4

=item * C<$server_name> server name

=back

returns website url

=cut

sub website_name {
    my $server_name = shift;

    return get_qa_node_website_url($server_name) if ($server_name =~ /^qa\d+$/);

    return request()->brand->website_name;
}

sub check_authorization {
    my $client = shift;

    return create_error({
            code              => 'AuthorizationRequired',
            message_to_client => localize('Please log in.')}) unless $client;

    return create_error({
            code              => 'DisabledClient',
            message_to_client => localize('This account is unavailable.')}) unless $client->is_available;

    return;
}

=head2 is_verification_token_valid

Checks the validity of the verification token.
Also, deletes the token if it's not a C<dry_run>.

Takes the following parameters:

=over 5

=item * C<$token> - Token to be validated

=item * C<$email> - Email of the client

=item * C<$created_for> - The type that the token is created for

=item * C<$is_dry_run> - [Optional] If true, won't delete the token

=item * C<$created_by> - [Optional] The creator of the token

=back

Returns a hashref containing C<< { status => 1 } >> if successfully validated.
Otherwise, an error.

=cut

sub is_verification_token_valid {
    my ($token, $email, $created_for, $is_dry_run, $created_by) = @_;

    my $verification_token = BOM::Platform::Token->new({token => $token});
    my $response           = create_error({
            code              => "InvalidToken",
            message_to_client => localize('Your token has expired or is invalid.')});

    return $response unless ($verification_token and $verification_token->token);
    unless ($verification_token->{created_for} eq $created_for) {
        $verification_token->delete_token;
        return $response;
    }

    if (    $verification_token->email
        and $verification_token->email eq $email
        and not $verification_token->created_by)
    {
        $response = {status => 1};
    } elsif ($verification_token->email
        and $verification_token->email eq $email
        and $verification_token->created_by
        and $verification_token->created_by eq $created_by)
    {
        $response = {status => 1};
    } else {
        $response = create_error({
                code              => "BadSession",
                message_to_client => localize('The token you used is invalid in this session. Please get a new token and try again.')});
    }
    $verification_token->delete_token unless $is_dry_run;

    return $response;
}

=head2 check_password_trading_platform

Description: Checks password validation for trading platforms

Takes the following parameters:

=over 4

=item - platform: Abbreviation of the trading platform

=item - email: (optional)  A short string acting as a key for this error.

=item - new_password: (optional) Password to check for validation

=item - old_password: (optional)  old_password if user has old password

=item - user_pass: (optional) User entered password that we validate against old_password

=back

    Returns undef if successfully validated.
    
=cut

sub check_password_trading_platform {

    my $args         = shift;
    my $email        = $args->{email};
    my $new_password = $args->{new_password};
    my $platform     = $args->{platform};

    if (exists $args->{old_password} && exists $args->{user_pass}) {
        my $old_password = $args->{old_password};
        my $user_pass    = $args->{user_pass};

        return BOM::RPC::v3::Utility::create_error({
                code              => 'PasswordError',
                message_to_client => localize('That password is incorrect. Please try again.')}
        ) unless (BOM::User::Password::checkpw($old_password, $user_pass));

        return BOM::RPC::v3::Utility::create_error({
                code              => 'PasswordError',
                message_to_client => localize('Current password and new password cannot be the same.')}) if ($new_password eq $old_password);
    }

    return BOM::RPC::v3::Utility::create_error({
            code              => 'PasswordError',
            message_to_client => localize(
                'Your password must be 8 to 16 characters long. It must include lowercase, uppercase letters, numbers and special characters.')}
    ) if $platform eq 'mt5' && $new_password !~ REGEX_TRADING_PLATFORM_PASSWORD_VALIDATION_MT5;

    return BOM::RPC::v3::Utility::create_error({
            code              => 'PasswordError',
            message_to_client => localize('Your password must be 8 to 25 characters long. It must include lowercase, uppercase letters and numbers.')}
    ) if $platform eq 'dxtrade' && $new_password !~ REGEX_TRADING_PLATFORM_PASSWORD_VALIDATION;

    return BOM::RPC::v3::Utility::create_error({
            code              => 'PasswordError',
            message_to_client => localize('You cannot use your email address as your password.')}) if lc $new_password eq lc $email;

    return undef;
}

=head2 notify_financial_assessment

return true if a notification needs to be displayed for the client if Financial assessment was not completed.
- if BVI , labuan are available as mt5 trading platforms.
- Financial assesment is not complete.
- mt5 accounts exists in SVG jurisdiction.

=over 4

=item * C<client> - bom client object.

=back

return binary value indicating if notification should be added or not

=cut

sub notify_financial_assessment {
    my $client = shift;
    # get financial assessment information if completed then we return 0
    # this is for svg accounts
    my $financial_assessment = BOM::User::FinancialAssessment::decode_fa($client->financial_assessment());
    return 0 if BOM::User::FinancialAssessment::is_section_complete($financial_assessment, 'financial_information', $client->landing_company->short);

    # get the trading plaforms supported from here
    my $platform = BOM::TradingPlatform->new(
        platform => 'mt5',
        client   => $client
    );
    my $platforms           = $platform->available_accounts({country_code => $client->residence});
    my @supported_platforms = grep { $_->{shortcode} ne "svg" } @$platforms;
    return 0 if !@supported_platforms;

    # get mt5 real account and see if they are svg
    my $loginids = $client->user->loginid_details;
    my @accounts = grep {
                defined $loginids->{$_}{'attributes'}{'account_type'}
            and defined $loginids->{$_}{'attributes'}{'landing_company'}
            and defined $loginids->{$_}{'account_type'}
            and defined $loginids->{$_}{'platform'}
            and $loginids->{$_}{'account_type'} eq "real"
            and $loginids->{$_}{'attributes'}{'landing_company'} eq "svg"
            and $loginids->{$_}{'attributes'}{'account_type'} eq "real"
            and $loginids->{$_}{'platform'} eq "mt5"
    } keys %$loginids;
    return 1 if @accounts;

}

=head2 validate_mt5_password
    Validates the mt5 password must be of 8-16 characters long.
    It must also have at least 1 character of each uppercase letters, lowercase letters, special characters and numbers.
    Returns error message code if check fails else undef.
=cut

sub validate_mt5_password {
    my $args       = shift;
    my $email      = $args->{email};
    my $invest_pwd = $args->{invest_password};
    my $main_pwd   = $args->{main_password};

    if (defined $main_pwd) {
        return 'IncorrectMT5PasswordFormat'    if $main_pwd !~ REGEX_TRADING_PLATFORM_PASSWORD_VALIDATION_MT5;
        return 'MT5PasswordEmailLikenessError' if lc $main_pwd eq lc $email;
    }

    if (defined $invest_pwd) {
        return 'IncorrectMT5PasswordFormat'
            if $invest_pwd && $invest_pwd !~ REGEX_TRADING_PLATFORM_PASSWORD_VALIDATION_MT5;    # invest password can also be empty.
        return 'MT5PasswordEmailLikenessError' if lc $invest_pwd eq lc $email;
    }

    return 'MT5SamePassword' if defined $main_pwd && defined $invest_pwd && $main_pwd eq $invest_pwd;

    return undef;
}

=head2 validate_password_with_attempts

Check new password against user password.

=over 4

=item * C<$new_password> - new password

=item * C<$user_password> - current password

=item * C<$loginid> - client loginid

=back

Returns undef on success, returns error code otherwise.

=cut

sub validate_password_with_attempts {
    my ($new_password, $user_password, $loginid) = @_;
    my $redis = BOM::Config::Redis::redis_replicated_write();
    my $key   = "PASSWORD_CHECK_COUNTER:$loginid";

    $redis->set(
        $key,
        MAX_PASSWORD_CHECK_ATTEMPTS,
        'EX' => 60,    # expires after 1min
        'NX'
    );

    if ($redis->get($key) == 0) {
        return 'PasswordReset';
    }

    unless (BOM::User::Password::checkpw($new_password, $user_password)) {
        $redis->incrbyfloat($key, -1);
        return 'PasswordError';
    }

    $redis->del($key);
    return;
}

our %ImmutableFieldError = do {
    ## no critic(TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'redefine';
    local *localize = sub { die 'you probably wanted an arrayref for this localize() call' if @_ > 1; shift };
    (
        place_of_birth            => localize("Your place of birth cannot be changed."),
        date_of_birth             => localize("Your date of birth cannot be changed."),
        salutation                => localize("Your salutation cannot be changed."),
        first_name                => localize("Your first name cannot be changed."),
        last_name                 => localize("Your last name cannot be changed."),
        citizen                   => localize("Your citizenship cannot be changed."),
        account_opening_reason    => localize("Your account opening reason cannot be changed."),
        secret_answer             => localize("Your secret answer cannot be changed."),
        secret_question           => localize("Your secret question cannot be changed."),
        tax_residence             => localize("Your tax residence cannot be changed."),
        tax_identification_number => localize("Your tax identification number cannot be changed."),
        address_city              => localize("Your address cannot be changed."),
        address_line_1            => localize("Your address cannot be changed."),
        address_line_2            => localize("Your address cannot be changed."),
        address_postcode          => localize("Your address cannot be changed."),
        address_state             => localize("Your address cannot be changed."),
    );
};

sub mask_app_id {
    my ($id, $time) = @_;

    # this is the date when we started populating source with app_id, before this
    # there were random numbers so don't want to send them back
    $id = undef if ($time and Date::Utility->new($time)->is_before(Date::Utility->new("2016-03-01")));

    return $id;
}

sub error_map {
    ## no critic(TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'redefine';

    local *localize = sub { die 'you probably wanted an arrayref for this localize() call' if @_ > 1; shift };

    return {
        'email unverified'  => localize('Your email address is unverified.'),
        'no residence'      => localize('Your account has no country of residence.'),
        'invalid residence' => localize('Sorry, our service is not available for your country of residence.'),
        'duplicate email'   => localize(
            'Your provided email address is already in use by another Login ID. According to our terms and conditions, you may only register once through our site.'
        ),
        'duplicate name DOB' =>
            localize('Sorry, it looks like you already have a real money account with us. Only one real money account is allowed for each client.'),
        'too young'          => localize('Sorry, you are too young to open an account.'),
        'insufficient score' => localize(
            'Unfortunately your answers to the questions above indicate that you do not have sufficient financial resources or trading experience to be eligible to open a trading account at this time.'
        ),
        invalid                    => localize('Sorry, account opening is unavailable.'),
        InvalidAccount             => localize('Sorry, account opening is unavailable.'),
        InvalidAccountRegion       => localize('Sorry, account opening is unavailable in your region.'),
        PostcodeRequired           => localize('Postcode is required for UK residents.'),
        PoBoxInAddress             => localize('P.O. Box is not accepted in address.'),
        DuplicateVirtualWallet     => localize('Sorry, a virtual wallet account already exists. Only one virtual wallet account is allowed.'),
        InvalidDateOfBirth         => localize('Date of birth is invalid.'),
        InvalidPlaceOfBirth        => localize('Please enter a valid place of birth.'),
        InsufficientAccountDetails => localize('Please provide complete details for your account.'),
        InvalidCitizenship         => localize('Sorry, our service is not available for your country of citizenship.'),
        InvalidResidence           => localize('Sorry, our service is not available for your country of residence.'),
        InvalidState               => localize('Sorry, the provided state is not valid for your country of residence.'),
        InvalidDateFirstContact    => localize('Date first contact is invalid.'),
        InvalidBrand               => localize('Brand is invalid.'),
        CannotChangeAccountDetails => localize('You may not change these account details.'),
        UnwelcomeAccount           => localize('We are unable to do that because your account has been restricted. If you need help, let us know.'),
        InvalidPhone               => localize('Please enter a valid phone number, including the country code (e.g. +15417541234).'),
        NeedBothSecret             => localize('Need both secret question and secret answer.'),
        DuplicateAccount       => localize('Sorry, an account already exists with those details. Only one real money account is allowed per client.'),
        DuplicateWallet        => localize('Sorry, a wallet already exists with those details.'),
        BelowMinimumAge        => localize('Value of date of birth is below the minimum age required.'),
        FinancialAccountExists => localize('You already have a financial money account. Please switch accounts to trade financial products.'),
        NewAccountLimitReached => localize('You have created all accounts available to you.'),
        NoResidence            => localize('Please set your country of residence.'),
        SetExistingAccountCurrency => localize('Please set the currency for your existing account [_1], in order to create more accounts.'),
        P2PRestrictedCountry       => localize("Deriv P2P is unavailable in your country. Please provide a different account opening reason."),
        InputValidationFailed      => localize("This field is required."),
        NotAgeVerified             => localize('Please verify your identity.'),
        InvalidEmail               => localize('This email address is invalid.'),
        InvalidUser                => localize('No user found.'),

        # validate_paymentagent_details
        RequiredFieldMissing       => localize('This field is required.'),
        NoAccountCurrency          => localize('Please set the currency for your existing account.'),
        PaymentAgentsSupended      => localize('Payment agents are suspended in your residence country.'),
        DuplicateName              => localize('You cannot use this name, because it is taken by someone else.'),
        MinWithdrawalIsNegative    => localize('The requested minimum amount must be greater than zero.'),
        MaxWithdrawalIsLessThanMin => localize('The requested maximum amount must be greater than minimum amount.'),
        ValueOutOfRange            => localize('It must be between [_1] and [_2].'),
        CodeOfConductNotApproved   => localize('Code of conduct should be accepted.'),
        TooManyDecimalPlaces       => localize('Only [_1] decimal places are allowed.'),
        InvalidNumericValue        => localize('The numeric value is invalid.'),
        InvalidStringValue         => localize('This field must contain at least one alphabetic character.'),
        InvalidArrayValue          => localize('Valid array was expected.'),

        DuplicateCurrency        => localize("Please note that you are limited to only one [_1] account."),
        CannotChangeWallet       => localize("Sorry, your trading account is already linked to a wallet."),
        CurrencyMismatch         => localize("Please ensure your trading account currency is the same as your wallet account currency."),
        CannotLinkWallet         => localize("Sorry, we couldn't link your trading account to this wallet."),
        InvalidWalletAccount     => localize("Sorry, we couldn't find your wallet account."),
        InvalidMT5Account        => localize("Sorry, we couldn't find your MT5 account."),
        DXInvalidAccount         => localize("Sorry, we couldn't find your DXTrader account."),
        InvalidTradingAccount    => localize("Sorry, we couldn't find your trading account."),
        CannotLinkVirtualAndReal => localize("Please ensure your trading account type is the same as your wallet account type."),
        ForbiddenPostcode        =>
            localize("Our services are not available for your country of residence. Please see our terms and conditions for more information."),

        CurrencySuspended           => localize("The provided currency [_1] is not selectable at the moment."),
        InvalidCryptoCurrency       => localize("The provided currency [_1] is not a valid cryptocurrency."),
        ExperimentalCurrency        => localize("This currency is temporarily suspended. Please select another currency to proceed."),
        DuplicateWallet             => localize('Sorry, a wallet already exists with those details.'),
        CurrencyChangeIsNotPossible => localize('Change of currency is not allowed for an trading account.'),
        MT5AccountExisting          => localize('Change of currency is not allowed due to an existing MT5 real account.'),
        DXTradeAccountExisting      => localize('Change of currency is not allowed due to an existing Deriv X real account.'),
        DepositAttempted            => localize('Change of currency is not allowed after the first deposit attempt.'),
        AccountWithDeposit          => localize('Change of currency is not allowed for an existing account with previous deposits.'),

        CryptoAccount          => localize('Account currency is set to cryptocurrency. Any change is not allowed.'),
        CurrencyNotApplicable  => localize('The provided currency [_1] is not applicable for this account.'),
        CurrencyNotAllowed     => localize("The provided currency [_1] is not selectable at the moment."),
        CurrencyTypeNotAllowed => localize('Please note that you are limited to one fiat currency account.'),

        CurrencySuspended     => localize("The provided currency [_1] is not selectable at the moment."),
        InvalidCryptoCurrency => localize("The provided currency [_1] is not a valid cryptocurrency."),
        ExperimentalCurrency  => localize("This currency is temporarily suspended. Please select another currency to proceed."),
        DuplicateWallet       => localize('Sorry, a wallet already exists with those details.'),
        AllowCopiersError     => localize("Copier can't be a trader."),
        TaxInformationCleared => localize('Tax information cannot be removed once it has been set.'),
        TINDetailsMandatory   =>
            localize('Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.'),
        TINDetailInvalid              => localize('The provided Tax Identification Number is invalid. Please try again.'),
        ProfessionalNotAllowed        => localize('Professional status is not applicable to your account.'),
        ProfessionalAlreadySubmitted  => localize('You already requested professional status.'),
        IncompleteFinancialAssessment => localize("The financial assessment is not complete"),
        SelfExclusion                 => localize(
            'You have chosen to exclude yourself from trading on our website until [_1]. If you are unable to place a trade or deposit after your self-exclusion period, please contact us via live chat.'
        ),
        SetSelfExclusionError      => localize('Sorry, but setting your maximum deposit limit is unavailable in your country.'),
        PaymentAgentNotAvailable   => localize('The payment agent facility is not available for this account.'),
        DXSuspended                => localize('Deriv X account management is currently suspended.'),
        DXGeneral                  => localize('This service is currently unavailable. Please try again later.'),
        DXServerSuspended          => localize('This feature is suspended for system maintenance. Please try later.'),
        DXNoServer                 => localize('Server must be provided for Deriv X service token.'),
        DXNoAccount                => localize('You do not have a Deriv X account on the provided server.'),
        DXTokenGenerationFailed    => localize('Token generation failed. Please try later.'),
        DifferentLandingCompanies  => localize('Payment agent transfers are not allowed for the specified accounts.'),
        CTraderGeneral             => localize('This service is currently unavailable. Please try again later.'),
        CTraderAccountNotFound     => localize('No cTrader accounts found.'),
        CTraderSuspended           => localize('cTrader account management is currently suspended.'),
        CTraderServerSuspended     => localize('This feature is suspended for system maintenance. Please try later.'),
        CTraderDepositSuspended    => localize('cTrader deposit is currently suspended.'),
        CTraderWithdrawalSuspended => localize('cTrader withdrawal is currently suspended.'),

        # Payment agent application
        PaymentAgentAlreadyApplied          => localize("You've already submitted a payment agent application request."),
        PaymentAgentAlreadyExists           => localize('You are already an approved payment agent.'),
        PaymentAgentStatusNotEligible       => localize('You are not eligible to apply to be a payment agent.'),
        PaymentAgentClientStatusNotEligible => localize('You cannot apply to be a payment agent due to your account status.'),
        PaymentAgentInsufficientDeposit     => localize(
            'Your account does not meet the deposit requirement of [_1] [_2]. Note that deposits from credit cards and certain e-wallets do not count towards the deposit requirement.'
        ),

        # Paymentagent transfer
        PaymentAgentDailyCountExceeded =>
            localize('Payment agent transfers are not allowed, as you have exceeded the maximum allowable transactions for today.'),
        OpenP2POrders => localize('You cannot change account currency while you have open P2P orders.'),

        #transfer between accounts
        InvalidLoginidFrom           => localize('You are not allowed to transfer from this account.'),
        InvalidLoginidTo             => localize('You are not allowed to transfer to this account.'),
        IncompatibleDxtradeToMt5     => localize('You are not allowed to transfer to this account.'),
        IncompatibleMt5ToDxtrade     => localize('You are not allowed to transfer to this account.'),
        IncompatibleDerivezToMt5     => localize('You are not allowed to transfer to this account.'),
        IncompatibleMt5ToDerivez     => localize('You are not allowed to transfer to this account.'),
        IncompatibleDxtradeToDxtrade => localize('Transfer between two Deriv X accounts is not allowed.'),
        CashierLocked                => localize('Your account cashier is locked. Please contact us for more information.'),
        WithdrawalLockedStatus       => localize('You cannot perform this action, as your account is withdrawal locked.'),
        NoWithdrawalOrTradingStatus  => localize('You cannot perform this action, as your account is withdrawal locked.'),
        TransferCurrencyMismatch     => localize('Currency provided is different from account currency.'),
        TransferSetCurrency          => localize('Please set the currency for your existing account [_1].'),
        DifferentFiatCurrencies      => localize('Account transfers are not available for accounts with different currencies.'),
        ExchangeRatesUnavailable     => localize('Sorry, transfers are currently unavailable. Please try again later.'),
        TransferBlocked              => localize("Transfers are not allowed for these accounts."),
        TransferInvalidAmount        => localize("Please provide valid amount."),

        WalletAccountsNotAllowed            => localize('Transfer between wallet accounts is not allowed.'),
        IncompatibleClientLoginidClientFrom => localize("You can only transfer from the current authorized client's account."),
        IncompatibleCurrencyType            => localize('Please provide valid currency.'),
        IncompatibleLandingCompanies        => localize('Transfers between accounts are not available for your account.'),
        CurrencyNotLegalLandingCompany      => localize('Currency provided is not valid for your account.'),
        DisabledAccount                     => localize("You cannot perform this action, as your account [_1] is currently disabled."),
        UnwelcomeStatus                     => localize("We are unable to transfer to [_1] because that account has been restricted."),
        EmptySourceCurrency                 => localize('Please deposit to your account.'),

        # IDV error
        NoAuthNeeded        => localize("You don't need to authenticate your account at this time."),
        NoSubmissionLeft    => localize("You've reached the maximum number of attempts for verifying your proof of identity with this method."),
        NotSupportedCountry => localize("The country you selected isn't supported."),
        InvalidDocumentType => localize("The document type you entered isn't supported for the country you selected."),
        IdentityVerificationDisabled   => localize("This verification method is currently unavailable."),
        InvalidDocumentNumber          => localize("It looks like the document number you entered is invalid. Please check and try again."),
        AlreadyAgeVerified             => localize("Your age already been verified."),
        IdentityVerificationDisallowed => localize("This method of verification is not allowed. Please try another method."),
        ClaimedDocument                => localize(
            "This document number was already submitted for a different account. It seems you have an account with us that doesn't need further verification. Please contact us via live chat if you need help."
        ),
        ExpiredDocument           => localize("The document you used appears to be expired. Please use a valid document."),
        InvalidDocumentAdditional => localize("It looks like the document details you entered are invalid. Please check and try again."),
        UnderageBlocked           => localize("The document you used appears to be from an underage individual. Please use a valid document."),
        ClientMissing             => localize("The client is missing, please provide a valid client."),
        IDVResultMissing          => localize("The IDV result is missing."),
        DocumentMissing           => localize("The document is missing."),
        IssuingCountryMissing     => localize("The field issuing country is required."),
        DocumentTypeMissing       => localize("The field document type is required."),
        DocumentNumberMissing     => localize("The field document number is required."),
    };
}

=head2 filter_siblings_by_landing_company

This returns sibling per landing company i.e
filters out different landing company siblings

=cut

sub filter_siblings_by_landing_company {
    my ($landing_company_name, $siblings) = @_;

    return {map { $_ => $siblings->{$_} } grep { $siblings->{$_}->{landing_company_name} eq $landing_company_name } keys %$siblings};
}

=head2 get_available_currencies

    get_available_currencies($siblings, $landing_company_name)

    Get the currency statuses (fiat and crypto) of the clients, based on the landing company.

=cut

sub get_available_currencies {
    my ($siblings, $landing_company_name) = @_;

    # Get all the currencies (as per the landing company) and from client
    my $legal_allowed_currencies = LandingCompany::Registry->by_name($landing_company_name)->legal_allowed_currencies;

    my @client_currencies = map { $siblings->{$_}->{currency} } keys %$siblings;

    # Get available currencies for this landing company
    my @available_currencies = @{filter_out_suspended_cryptocurrencies($landing_company_name)};

    # Check if client has a fiat currency or not
    # If yes, then remove all fiat currencies
    my $has_fiat = any { (LandingCompany::Registry::get_currency_type($_) // '') eq 'fiat' } @client_currencies;

    if ($has_fiat) {
        @available_currencies = grep { $legal_allowed_currencies->{$_}->{type} ne 'fiat' } @available_currencies;
    }

    # Filter out the cryptocurrencies used by client
    @available_currencies = grep {
        my $currency = $_;
        !any(sub { $_ eq $currency }, @client_currencies)
    } @available_currencies;

    return @available_currencies;
}

sub validate_uri {
    my $original_url = shift;
    my $url          = URI->new($original_url);

    if ($original_url =~ /[^[:ascii:]]/) {
        return localize('Unicode is not allowed in URL');
    }

    if (not defined $url->scheme or $url->scheme !~ /^[a-z][a-z0-9.+\-]*$/) {
        return localize('The given URL scheme is not valid');
    }

    if ($url->fragment) {
        return localize('URL should not have fragment');
    }

    if ($url->query) {
        return localize('URL should not have query');
    }

    if ($url->has_recognized_scheme) {
        if ($url->userinfo) {
            return localize('URL should not have user info');
        }

        if ($url->port != 80 && $url->port != 443) {
            return localize('Only ports 80 and 443 are allowed');
        }

        my $host = $url->host;
        if (!$host || $original_url =~ /https?:\/\/.*(\:|\@|\#|\?)+/) {
            return localize('Invalid URL');
        }
    }

    return undef;
}

=head2 validate_app_name

    validate_app_name($app_name);

    Validate 3rd party app name not to include 'deriv' and/or 'binary' in it or words with other characters that look similar.

=cut

sub validate_app_name {
    my $app_name = shift;

    # Precompiled 'deriv' and 'binary' regex with case insensitivity
    # must be able to catch spelling with a symbol between letters, e.g. 'd.e_r~i*v'

    # Precompiled letters, used in words 'deriv' and 'binary', /i - case insesitive
    my $d_re = qr/[dⓓ⒟ḋḍḏḑḓḒḊḌḎḐⅾⅆ𝐝𝑑𝒅𝒹𝓭𝔡𝕕𝖉𝖽𝗱𝘥𝙙𝚍ԁᏧᑯꓒⅮⅅ𝐃𝐷𝑫𝒟𝓓𝔇𝔻𝕯𝖣𝗗𝘋𝘿𝙳ᎠᗞᗪꓓɗɖƌđĐÐƉ₫ꝺᑻᒇ]/i;
    my $e_re = qr/[eⓔ⒠ℯ∊€ḕḙḛḝẹẻẽếềểễệἐἑἒἓἔἕὲέℰℇ∃ḔḖḘḚḜẸẺẼẾỀỂỄỆῈΈἘἙἚἛἜἝ3℮ｅℯⅇ𝐞𝑒𝒆𝓮𝔢𝕖𝖊𝖾𝗲𝘦𝙚𝚎ꬲеҽ ⷷ⋿Ｅℰ𝐄𝐸𝑬𝓔𝔈𝔼𝕰𝖤𝗘𝘌𝙀𝙴Ε𝚬𝛦𝜠𝝚𝞔ЕⴹᎬꓰěĚɇɆҿ∑⅀Σ𝚺𝛴𝜮𝝨𝞢ⵉ]/i;
    my $r_re = qr/[rⓡ⒭Իṟṙṛṝℛℜℝ℟ṘṚṜṞ𝐫𝑟𝒓𝓇𝓻𝔯𝕣𝖗𝗋𝗿𝘳𝙧𝚛ꭇꭈᴦⲅгℛℜℝ𝐑𝑅𝑹𝓡𝕽𝖱𝗥𝘙𝙍𝚁ƦᎡᏒᖇꓣɽɼɍғᵲґ₨]/i;
    my $i_re =
        qr/[iⓘ⒤ї유ḭḯỉịἰἱἲἳἴἵἶἷῐῑῒΐῖῗὶίЇℐḬḭḮḯỈỉỊịἰἱἲἳἴἵἶἷἸἹἺἻἼἽἾἿῐῑῒΐῖῗῘῙῚΊὶί1!|l˛⍳ｉⅰℹⅈ𝐢𝑖𝒊𝒾𝓲𝔦𝕚𝖎𝗂𝗶𝘪𝙞𝚒ı𝚤ɪɩιιͺ𝛊𝜄𝜾𝝸𝞲іꙇӏ⍸ǐǏɨᵻⅱⅲĳｊⅉ𝐣𝑗𝒋𝒿𝓳𝔧𝕛𝖏𝗃𝗷𝘫𝙟𝚓ϳј∣⏽￨1۱𐌠𝟏𝟙𝟣𝟭𝟷IＩⅠℐℑ𝐈𝐼𝑰𝓘𝕀𝕴𝖨𝗜𝘐𝙄𝙸Ɩｌⅼℓ𝐥𝑙𝒍𝓁𝓵𝔩𝕝𝖑𝗅𝗹𝘭𝙡𝚕ǀΙ𝚰𝛪𝜤𝝞𝞘ⲒІӀⵏᛁꓲ𐌉łŁɭƗƚɫŀĿᒷ🄂⒈ǉĲǈǇ‖∥Ⅱǁ⒒Ⅲʪ₶ɮʫ∫ꭍ]/i;
    my $v_re = qr/[vⓥ⒱ṽṿṼṾ𝐮𝑢𝒖𝓊𝓾𝔲𝕦𝖚𝗎𝘂𝘶𝙪𝚞ꞟᴜꭎꭒʋυ𝛖𝜐𝝊𝞄𝞾ս∪⋃𝐔𝑈𝑼𝒰𝓤𝔘𝕌𝖀𝖴𝗨𝘜𝙐𝚄ՍሀᑌꓴǔǓ℧ᘮᘴᵿ∨⋁ｖⅴ𝐯𝑣𝒗𝓋𝓿𝔳𝕧𝖛𝗏𝘃𝘷𝙫𝚟ᴠν𝛎𝜈𝝂𝝼𝞶ѵ۷Ⅴ𝐕𝑉𝑽𝒱𝓥𝔙𝕍𝖁𝖵𝗩𝘝𝙑𝚅ѴⴸᏙᐯꓦᐻ]/i;

    my $b_re = qr/[bⓑ⒝ദ൫♭ḃḅḇℬḂḄḆ𝐛𝑏𝒃𝒷𝓫𝔟𝕓𝖇𝖻𝗯𝘣𝙗𝚋ƄЬᏏᑲᖯＢℬ𝐁𝐵𝑩𝓑𝔅𝔹𝕭𝖡𝗕𝘉𝘽𝙱ꞴΒ𝚩𝛣𝜝𝝗𝞑ВᏴᗷꓐ𐌁ɓᑳƃƂБƀҍҌѣѢᑿᒁᒈЫвꞵβϐ𝛃𝛽𝜷𝝱𝞫Ᏸ]/i;
    my $n_re = qr/[nⓝ⒩ηℵസ൩നṅṇṉṋἠἡἢἣἤἥἦἧὴήᾐᾑᾒῃῄῆῇℕ₦ṄṆṈṊ𝐧𝑛𝒏𝓃𝓷𝔫𝕟𝖓𝗇𝗻𝘯𝙣𝚗ոռＮℕ𝐍𝑁𝑵𝒩𝓝𝔑𝕹𝖭𝗡𝘕𝙉𝙽Ν𝚴𝛮𝜨𝝢𝞜Ⲛꓠɳƞη𝛈𝜂𝜼𝝶𝞰ƝᵰǌǋǊ№]/i;
    my $a_re = qr/[aⓐ⒜ᾰḁἀἁἂἃἄἅἆἇạảầấẩẫậắằẳẵặẚᾱᾲᾳᾴᾶᾷѦẶἈἉἊἋἌἍἎἏẠẢẤẦẨẪẬẮẰẲA⍺ａ𝐚𝑎𝒂𝒶𝓪𝔞𝕒𝖆𝖺𝗮𝘢𝙖𝚊ɑα𝛂𝛼𝜶𝝰𝞪а ⷶＡ𝐀𝐴𝑨𝒜𝓐𝔄𝔸𝕬𝖠𝗔𝘈𝘼𝙰Α𝚨𝛢𝜜𝝖𝞐АᎪᗅꓮǎǍȧȦẚ]/i;
    my $y_re = qr/[yⓨ൮⑂ഴẙỳỷỵỹẏㄚẎὙὛὝὟῨῩῪΎỲỴỶỸɣᶌｙ𝐲𝑦𝒚𝓎𝔂𝔶𝕪𝖞𝗒𝘆𝘺𝙮𝚢ʏỿꭚγℽ𝛄𝛾𝜸𝝲𝞬уүყＹ𝐘𝑌𝒀𝒴𝓨𝔜𝕐𝖄𝖸𝗬𝘠𝙔𝚈Υϒ𝚼𝛶𝜰𝝪𝞤ⲨУҮᎩᎽꓬƴɏұ¥ɎҰ]/i;

    # Precompiled word 'deriv', /x - allow comments and whitespaces
    my $deriv_regex = qr/
        $d_re.?
        $e_re.?
        $r_re.?
        $i_re.?
        $v_re
    /x;

    # Precompiled word 'binary', /x - allow comments and whitespaces
    my $binary_regex = qr/
        $b_re.?
        $i_re.?
        $n_re.?
        $a_re.?
        $r_re.?
        $y_re
    /x;

    # Check that app_name doesn't include 'deriv' and/or 'binary' or words that look similar
    if ($app_name =~ m/$deriv_regex|$binary_regex/) {
        return localize("App name can't include 'deriv' and/or 'binary' or words that look similar.");
    }

    return undef;
}

sub set_professional_status {
    my ($client, $professional, $professional_requested) = @_;
    my $error;

    # Set checks in variables
    my $cr_mf_valid      = $client->landing_company->support_professional_client;
    my $set_prof_status  = $professional           && !$client->status->professional           && $cr_mf_valid;
    my $set_prof_request = $professional_requested && !$client->status->professional_requested && $cr_mf_valid;

    try {
        $client->status->set('professional',           'SYSTEM', 'Mark as professional as requested') if $set_prof_status;
        $client->status->set('professional_requested', 'SYSTEM', 'Professional account requested')    if $set_prof_request;
    } catch {
        $error = client_error();
    }
    return $error if $error;

    send_professional_requested_email($client->loginid, $client->residence) if $set_prof_request;

    return undef;
}

sub send_professional_requested_email {
    my ($loginid, $residence) = @_;

    return unless $loginid;

    my $brand = request()->brand;

    return send_email({
        from    => $brand->emails('system_generated'),
        to      => $brand->emails('compliance_ops'),
        subject => "$loginid requested for professional status, residence: " . ($residence // 'No residence provided'),
        message => ["$loginid has requested for professional status, please check and update accordingly"],
    });
}

=head2 _timed

Helper function for recording time elapsed via statsd.

=cut

sub _timed (&@) {    ## no critic (ProhibitSubroutinePrototypes)
    my ($code, $k, @args) = @_;
    my $start = Time::HiRes::time();
    my $exception;
    my $rslt;
    try {
        $rslt = $code->();
        $k .= '.success';
    } catch ($e) {
        $exception = $e;
        $k .= '.error';
    }
    my $elapsed = 1000.0 * (Time::HiRes::time() - $start);
    stats_timing($k, $elapsed, @args);
    die $exception if $exception;
    return $rslt;
}

=head2 longcode

Performs a longcode lookup for the given shortcodes.

Expects the following parameters in a single hashref:

=over 4

=item * C<currency> - the currency for the longcode text, e.g. C<USD>

=item * C<short_codes> - an arrayref of shortcode strings

=item * C<source> - the original app_id requesting this, false/undef if not available

=back

Returns a hashref which contains a single key with the shortcode to longcode mapping.

=cut

sub longcode {    ## no critic(Subroutines::RequireArgUnpacking)
    my $params = shift;
    die 'Invalid currency: ' . $params->{currency} unless ($params->{currency} =~ /^[a-zA-Z0-9]{2,20}$/);

    # We generate a hash, so we only need each shortcode once
    my @short_codes = uniqstr(@{$params->{short_codes}});
    my %longcodes;
    foreach my $shortcode (@short_codes) {
        try {
            $longcodes{$shortcode} = localize(shortcode_to_longcode($shortcode, $params->{currency}));
        } catch ($e) {
            # we do not want to warn for known error like legacy underlying
            if ($e !~ /unknown underlying/) {
                warn "exception is thrown when executing shortcode_to_longcode, parameters: " . $shortcode . ' error: ' . $e;
            }
            $longcodes{$shortcode} = localize('No information is available for this contract.');
        }
    }

    return {longcodes => \%longcodes};
}

=head2 filter_out_suspended_cryptocurrencies

    @valid_payout_currencies = filter_out_suspended_cryptocurrencies($landing_company);

This subroutine checks for suspended cryptocurrencies

Accepts: Landing company name

Returns: Sorted arrayref of valid CR currencies.

=cut

sub filter_out_suspended_cryptocurrencies {
    my $landing_company_name = shift;
    my @currencies           = keys %{LandingCompany::Registry->by_name($landing_company_name)->legal_allowed_currencies};

    my $suspended_currencies = BOM::Config::CurrencyConfig::get_suspended_crypto_currencies();

    my @valid_payout_currencies =
        sort grep { !exists $suspended_currencies->{$_} } @currencies;
    return \@valid_payout_currencies;
}

=head2 filter_out_signup_disabled_currencies

    $valid_signup_currencies = filter_out_signup_disabled_currencies($landing_company, $payout_currencies);

This subroutine checks for signup disabled currencies

Accepts: Landing company name, arrayref containing currencies

Returns: Sorted arrayref of valid currencies.

=cut

sub filter_out_signup_disabled_currencies {
    my ($landing_company_name, $payout_currencies) = @_;

    my $signup_disabled_currencies = BOM::Config::CurrencyConfig::get_signup_disabled_currencies($landing_company_name);
    my %signup_disabled_map        = map { $_ => 1 } $signup_disabled_currencies->@*;

    my @valid_currencies = sort grep { !$signup_disabled_map{$_} } $payout_currencies->@*;

    return \@valid_currencies;
}

=head2 check_ip_country

check for difference in between IP address country and client's residence

 Gets data from rpc authorize

Saves the mismatches in redis so cron_report_ip_mismatch can send an email to the compliance daily

=cut

sub check_ip_country {
    my %data  = @_;
    my $redis = BOM::Config::Redis::redis_replicated_write();
    use constant REDIS_MASTERKEY     => 'IP_COUNTRY_MISMATCH';
    use constant REDIS_TRACK_CHECKED => 'CHECKED_ID';

    return undef unless $data{country_code};
    # preventing it from rechecking the same id again and again
    return undef unless ($redis->hsetnx(REDIS_TRACK_CHECKED, $data{client_login_id}, 1));

    if (uc($data{client_residence}) ne uc($data{country_code})) {

        my $compiled_data = {
            date_time        => Date::Utility->new()->datetime_ddmmmyy_hhmmss_TZ(),
            client_residence => uc $data{client_residence},
            ip_address       => $data{client_ip},
            ip_country       => uc $data{country_code},
            broker_code      => $data{broker_code},
            loginid          => $data{client_login_id}};

        my $json_record = encode_json($compiled_data);
        $redis->hset(REDIS_MASTERKEY, $data{client_login_id} => $json_record);
    }

    return undef;
}

sub missing_details_error {
    my %args = @_;

    return create_error({
            code              => 'ASK_FIX_DETAILS',
            message_to_client => localize('Your profile appears to be incomplete. Please update your personal details to continue.'),
            details           => {fields => $args{details}}});
}

=head2 rule_engine_error

Calls C<create_error> parasing a rule engine exception which can be either a simple string message or a hash reference. Args:

=over 4

=item * C<error> - an error caught from rule engine.

=item * C<orverride_code> - the error code expected to appear in the output.

=back

Returns an error structured by C<create_error>

=cut

sub rule_engine_error {
    my ($error, $orverride_code, %options) = @_;

    # For scalar errors (without error code, etc) let it be caught and logged by default RPC error handling.
    # TODO: we've got to ultimately create a rule engine error class and check here if the error is it's instance.

    die $error unless (ref $error and ($error->{code} // $error->{error_code}));

    my $error_code = $error->{error_code} // $error->{code};

    my $message;
    $message = $ImmutableFieldError{$error->{details}->{field}} // ''
        if $error_code eq 'ImmutableFieldChanged' && $error->{details}->{field};

    return create_error_by_code(
        $error_code, %$error,
        message_to_client => $message,
        %options,
        override_code => $orverride_code,
    );
}

=head2 create_error_by_code

        call the create_error with error_code and message from error_map .

=over 4

=item * C<error_code>

A string from error_map HASH key.

=item * C<options> (optional)

Hash with advance options like override_code, details, message.

=back

Returns error format of create_error

=cut

sub create_error_by_code {
    my ($error_code, %options) = @_;

    my $message_to_client = $options{message_to_client} // error_map()->{$error_code} // BOM::Platform::Utility::error_map()->{$error_code};
    return BOM::RPC::v3::Utility::permission_error() unless $message_to_client;

    my @params;
    if ($options{params}) {
        @params = ref $options{params} eq 'ARRAY' ? @{$options{params}} : ($options{params});
    }

    return BOM::RPC::v3::Utility::create_error({
            code              => $options{override_code} || $error_code,
            message_to_client => localize($message_to_client, @params),
            $options{message} ? (message => $options{message}) : (),
            $options{details} ? (details => $options{details}) : ()});

}

=head2 verify_cashier_suspended

Check if the cashier is suspended for withdrawal or deposit.

=over 4

=item * C<currency> - The currency code.

=item * C<action> - Required for crypto currency, possible values are: deposit, withdrawal

=back

Returns 1 if suspended and 0 if not.

=cut

sub verify_cashier_suspended {
    my ($currency, $action) = @_;

    my $is_cryptocurrency = LandingCompany::Registry::get_currency_type($currency) eq 'crypto';

    if ($is_cryptocurrency) {
        return 1 if BOM::Config::CurrencyConfig::is_crypto_cashier_suspended();
        return 1 if ($action eq 'deposit'    && BOM::Config::CurrencyConfig::is_crypto_currency_deposit_suspended($currency));
        return 1 if ($action eq 'withdrawal' && BOM::Config::CurrencyConfig::is_crypto_currency_withdrawal_suspended($currency));
    } else {
        return 1 if BOM::Config::CurrencyConfig::is_cashier_suspended();
    }

    return 0;
}

=head2 verify_experimental_email_whitelisted

Check if email is whitelisted for experimental currency.

=over 4

=item * C<client>

client object.

=item * C<currency>

The currency code.

=back

Returns 1 if experimental is in emails list and 0 if not.

=cut

sub verify_experimental_email_whitelisted {
    my ($client, $currency) = @_;

    if (BOM::Config::CurrencyConfig::is_experimental_currency($currency)) {
        my $allowed_emails = BOM::Config::Runtime->instance->app_config->payments->experimental_currencies_allowed;
        my $client_email   = $client->email;
        return 1 if not any { $_ eq $client_email } @$allowed_emails;
    }

    return 0;
}

=head2 log_exception

A function to log exceptions in bom-rpc to the Datadog metrics.
B<Note>: Keep synced with bom-events L<BOM::Events::Utility>

Example usage:

Use inside a C<catch> block like this:

 try {
    .....
 }
 catch {
    ....
    log_exception();
 }

and it will automatically increment the exception count in Datadog if any exception occurs.

=over 4

=item * C<$caller> I<optional>

Caller string has to contain both method and package name.
It should be in this format B<Full::Path::Package::Name::Method_Name>

=back

Returns undef

=cut

sub log_exception {
    my $caller = shift;

    if (not $caller) {
        my $idx = 0;
        ++$idx while (caller $idx)[3] =~ /\b(?:eval|ANON|__ANON__|log_exception)\b/;

        $caller = (caller $idx)[3];
    }

    # Get correct package name instead of `BOM::RPC::Registry`
    my $caller_package = (caller 0)[0];

    _add_metric_on_exception($caller, $caller_package);

    return undef;
}

=head2 _add_metric_on_exception

Increment the exception count in the Datadog
Note : Keep synced with bom-events Utility.pm

Example usage:

_add_metric_on_exception(...)

Takes the following arguments as named parameters

=over 4

=item * C<caller>

Caller string has to contain both method and package name.
It should be in this format B<Full::Path::Package::Name::Method_Name>

=item * C<caller_package> I<optional>

An optional string which indicates the caller package name.

=back

Returns undef

=cut

sub _add_metric_on_exception {
    my ($caller, $caller_package) = @_;

    my @tags = _convert_caller_to_array_of_tags($caller, $caller_package);
    stats_inc(GENERIC_DD_STATS_KEY, {tags => \@tags});

    return undef;
}

=head2 _convert_caller_to_array_of_tags

Converts Caller into array of tags. Which contains package and method name.
Note : Keep synced with bom-events Utility.pm

Example usage:

_convert_caller_to_array_of_tags(...)

Takes the following arguments as named parameters

=over 4

=item * C<caller>

Caller string has to contain both method and package name.
It should be in this format B<Full::Path::Package::Name::Method_Name>

=item * C<caller_package> I<optional>

An optional string which indicates the caller package name.

=back

Returns array of tags which contains package and method name.

=cut

sub _convert_caller_to_array_of_tags {
    my ($caller, $caller_package) = @_;

    my @dd_tags       = ();
    my @array_subname = split("::", $caller);

    my $method  = pop @array_subname;
    my $package = join("::", @array_subname);
    $package = $caller_package if $caller_package;

    # Remove extra **RPC[]** which was added in L<BOM::RPC::Registry::import_dsl_into>.
    $method =~ s/RPC\[|\]//g;

    push @dd_tags, lc('package:' . $package) if ($package);
    push @dd_tags, lc('method:' . $method)   if ($method);

    return @dd_tags;
}

=head2 cashier_validation

Common validations for cashier and paymentagent_withdraw.
These validations do not require amount or other details, because
they are also run in verify_email for withdraw requests.
Takes the following arguments as named parameters

=over 4

=item * C<client>: C<BOM::User::Client> object

=item * C<type>: cashier action (deposit or withdraw) or verify_email type (payment_withdraw or paymentagent_withdraw)

=back

Returns an RPC error structure, or undef if no error.

=cut

sub cashier_validation {
    my ($client, $type) = @_;

    my $error_code = $type eq 'paymentagent_withdraw' ? 'PaymentAgentWithdrawError' : 'CashierForwardError';

    my $error_sub = sub {
        my ($message_to_client, $override_code) = @_;
        return create_error({
            code              => $override_code // $error_code,
            message_to_client => $message_to_client,
        });
    };

    return $error_sub->(localize('Terms and conditions approval is required.'), 'ASK_TNC_APPROVAL')
        if $client->is_tnc_approval_required and $type eq 'deposit';

    if ($type =~ /^(deposit|withdraw|payment_withdraw)$/) {
        my $validation_error = BOM::RPC::v3::Utility::validation_checks($client, ['compliance_checks']);
        return $validation_error if $validation_error;
    }

    my $rule_engine     = BOM::Rules::Engine->new(client => $client);
    my $validation_type = $type =~ /^(payment_withdraw|paymentagent_withdraw)$/ ? 'withdraw' : $type;
    my $is_cashier      = $type =~ /^paymentagent/                              ? 0          : 1;

    my $validation = BOM::Platform::Client::CashierValidation::validate(
        loginid           => $client->loginid,
        action            => $validation_type,
        is_internal       => 1,
        is_cashier        => $is_cashier,
        rule_engine       => $rule_engine,
        underlying_action => $type,
    );

    return create_error($validation->{error}) if exists $validation->{error};

    return;
}

=head2 set_trading_password_new_account

Validates or sets the user dx_trading_password when creating a new dxtrader trading account.

=over 4

=item * C<client>: C<BOM::User::Client> object

=item * C<trading_password>: plain password

=back

Returns scalar error code.

=cut

sub set_trading_password_new_account {
    my ($client, $trading_password) = @_;

    return 'PasswordRequired' unless $trading_password;

    if (my $current_password = $client->user->dx_trading_password) {
        return validate_password_with_attempts($trading_password, $current_password, $client->loginid);
    } else {
        my $error;
        if ($trading_password !~ REGEX_PASSWORD_VALIDATION) {
            $error = BOM::RPC::v3::Utility::create_error({
                    code              => 'PasswordError',
                    message_to_client =>
                        localize('Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.')});
        }
        if (lc $trading_password eq lc $client->email) {
            $error = BOM::RPC::v3::Utility::create_error({
                    code              => 'PasswordError',
                    message_to_client => localize('You cannot use your email address as your password.')});
        }

        die $error->{error} if $error;

        $client->user->update_dx_trading_password($trading_password);
        return undef;
    }
}

=head2 get_qa_node_website_url

Return website url as per environment (aws|openstack)

=over 4

=item * C<qa_number>: current qa's number

=back

Returns website URL as per QA number

=cut

sub get_qa_node_website_url {
    my ($qa_number) = @_;
    my $node_config = BOM::Config->qa_config()->{'nodes'}->{$qa_number . '.regentmarkets.com'};
    my $website     = $node_config->{'website'};
    return ($website =~ /^binaryqa/ ? "www.$website" : $website);
}

=head2 trading_platform_display_name

Returns the user-interface name of trading platform per Brand (binary|deriv)

=over 4

=item * C<platform>: trading platform name (mt5|dxtrade)

=back

Returns the display name of trading platform

=cut

sub trading_platform_display_name {
    my ($platform) = @_;

    die 'TradingPlatformRequired' unless $platform;

    my %display_name = (
        mt5     => request()->brand->name eq 'deriv' ? 'DMT5' : 'MT5',
        dxtrade => 'Deriv X'
    );

    return $display_name{$platform};
}

=head2 get_market_by_symbol

get market by symbol

=cut

sub get_market_by_symbol {
    my $symbol = shift;

    if (first { $_ eq $symbol } Finance::Underlying->symbols) {
        return Finance::Underlying->by_symbol($symbol)->market;
    } else {
        return $symbol . " does not exist";
    }
}

=head2 get_verification_uri

get verification uri from app_id

=cut

sub get_verification_uri {
    my $app_id = shift or return undef;
    return BOM::Database::Model::OAuth->new->get_verification_uri_by_app_id($app_id);
}

=head2 get_app_name

get app name from app_id

=cut

sub get_app_name {
    my $app_id = shift;
    return BOM::Database::Model::OAuth->new->get_names_by_app_id($app_id)->{$app_id};
}

1;

=head2 is_impersonating_client

Checks if this is an internal app like backend - if so we are impersonating an account. Takes the following arguments as named parameters

=over 4

=item - $token:  The token id used to authenticate with


=back

Returns a boolean

=cut

sub is_impersonating_client {
    my ($token) = @_;

    my $oauth_db = BOM::Database::Model::OAuth->new;
    my $app_id   = $oauth_db->get_app_id_by_token($token);
    return $oauth_db->is_internal($app_id);
}

=head2 request_email

send_email with subject and template name and args as input for sending

=over 4

=item - $email:  Email address to send
=item - @args: the arguments containing subject, template_name and template_args


=back

Returns a boolean

=cut

sub request_email {
    my ($email, $args) = @_;

    send_email({
        to                    => $email,
        subject               => $args->{subject},
        template_name         => $args->{template_name},
        template_args         => $args->{template_args},
        use_email_template    => 1,
        email_content_is_html => 1,
        use_event             => 1,
    });

    return 1;
}

=head2 set_client_locked_min_withdrawal_amount

save crypto minimum withdrawal amount in redis for client mentioned

=over 4

=item - $client_loginid:  client's loginid

=item - $minimum_withdrawal: minimum withdrawal amount

=back

Returns 1

=cut

sub set_client_locked_min_withdrawal_amount {
    my ($client_loginid, $minimum_withdrawal) = @_;
    return unless ($minimum_withdrawal && $client_loginid);
    my $redis_write = BOM::Config::Redis::redis_replicated_write();
    $redis_write->setex(CRYPTO_CONFIG_REDIS_CLIENT_MIN_AMOUNT . $client_loginid, CRYPTO_CONFIG_REDIS_CLIENT_MIN_AMOUNT_TTL, $minimum_withdrawal);
    return 1;
}

=head2 get_client_locked_min_withdrawal_amount

fetch crypto minimum withdrawal amount in redis for client mentioned

=over 4

=item - $client_loginid:  client's loginid

=back

Returns minimum amount if available else undef

=cut

sub get_client_locked_min_withdrawal_amount {
    my ($client_loginid) = @_;
    my $redis_read = BOM::Config::Redis::redis_replicated_read();
    return $redis_read->get(CRYPTO_CONFIG_REDIS_CLIENT_MIN_AMOUNT . $client_loginid) // undef;
}

=head2 handle_client_locked_min_withdrawal_amount

checks if minimum withdrawal amount is set for client then overwrited the global hashref `crypto_config` passed.
else gets the min_withdrawal_amount from config passed & sets it in redis

=over 4

=item - $crypto_config: crypto_config either from redis or via direct api

=item - $loginid: client's login id

=item - $currency: client's currency

=back

returns undef

=cut

sub handle_client_locked_min_withdrawal_amount {
    my ($crypto_config, $loginid, $currency) = @_;

    if (my $client_min_locked_amount = get_client_locked_min_withdrawal_amount($loginid)) {
        $crypto_config->{currencies_config}->{$currency}->{minimum_withdrawal} = $client_min_locked_amount;
    } else {
        my $minimum_withdrawal = $crypto_config->{currencies_config}->{$currency}->{minimum_withdrawal} // 0;
        set_client_locked_min_withdrawal_amount($loginid, $minimum_withdrawal) if $minimum_withdrawal;
    }
    return undef;
}

=head2 aggregate_ticks_history_metrics

It is responsible for aggregating ticks_history query metrics and determining the relation of
a given query. It takes three metrics as inputs: "start", "end", and "count",
representing the epoch timestamps of the query start and end times,
as well as the number of results returned by the query.

=over 4

=item - $start: Representing the epoch timestamps of the query start

=item - $end: Representing the epoch timestamps of the query end

=item - $count: An upper limit on ticks to receive

=back

returns ($aggregate_metrics, $relation)

=cut

sub aggregate_ticks_history_metrics {
    my ($start, $end, $count) = @_;

    my $start_midnight = Time::Moment->from_epoch($start)->at_midnight;
    my $end_midnight   = Time::Moment->from_epoch($end)->at_midnight;

    my $duration_times_count = (($end_midnight->epoch - $start_midnight->epoch) / 3600) * ($count / 5000);

    my $current_date = Time::Moment->now->at_midnight;
    my $query_date   = Time::Moment->from_epoch($start)->at_midnight;

    my $relation;
    if ($query_date eq $current_date) {
        $relation = "today";
    } elsif ($current_date eq $query_date->plus_days(1)) {
        $relation = "yesterday";
    } elsif ($query_date->is_after($current_date->minus_days(7))) {
        $relation = "last_week";
    } elsif ($query_date->is_after($current_date->minus_months(1))) {
        $relation = "last_month";
    } elsif ($query_date->is_after($current_date->minus_months(3))) {
        $relation = "last_3_months";
    } else {
        $relation = "more_than_3_months";
    }

    return ($duration_times_count, $relation);
}

=head2 obfuscate_token

the token passed in param will be masked with asterisk * for the initial 
characters leaving the ending unmasked character for hiding token information

=over 4

=item - $token: the token that requires obfuscation will be passed as param

=item - $unmasked_char_no: default value is 4 otherwise no of chars in hidden token

=back

=cut

sub obfuscate_token {
    my ($token, $unmasked_char_no) = @_;

    my $obfuscated_part = '*' x (length($token) - $unmasked_char_no);
    my $unmasked_part   = substr($token, -$unmasked_char_no);
    $token = $obfuscated_part . $unmasked_part;
    return $token;
}
