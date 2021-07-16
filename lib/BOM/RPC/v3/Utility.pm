
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
use YAML::XS qw(LoadFile);
use List::Util qw(any uniqstr shuffle minstr);
use List::UtilsBy qw(bundle_by);
use JSON::MaybeXS qw{encode_json};
use URI;
use Domain::PublicSuffix;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc stats_gauge);
use Time::HiRes;
use Time::Duration::Concise::Localize;
use Format::Util::Numbers qw/formatnumber/;
use JSON::MaybeUTF8 qw/encode_json_utf8 decode_json_utf8/;

use Quant::Framework;
use LandingCompany::Registry;
use Finance::Contract::Longcode qw(shortcode_to_longcode);

use BOM::Platform::Context qw(localize request);
use BOM::Platform::ProveID;
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
use BOM::MarketData qw(create_underlying);
use BOM::Platform::Event::Emitter;
use BOM::Platform::Client::CashierValidation;
use BOM::User;
use BOM::Transaction::Validation;
use BOM::Config;

use Exporter qw(import export_to_level);
our @EXPORT_OK = qw(longcode log_exception);

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

use constant MAX_PASSWORD_CHECK_ATTEMPTS => 5;

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
            $err = BOM::Transaction::Validation->new({clients => $client})->$act($client);
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

sub get_token_details {
    my $token = shift;

    return unless $token;

    my ($loginid, $creation_time, $epoch, $ua_fingerprint, $scopes, $valid_for_ip);
    if (length $token == 15) {    # access token
        my $m = BOM::Platform::Token::API->new;
        ($loginid, $creation_time, $scopes, $valid_for_ip) = @{$m->get_token_details($token, 1)}{qw/loginid creation_time scopes valid_for_ip/};
        return unless $loginid;
        $epoch = Date::Utility->new($creation_time)->epoch if $creation_time;
    } elsif (length $token == 32 && $token =~ /^a1-/) {
        my $m = BOM::Database::Model::OAuth->new;
        ($loginid, $creation_time, $ua_fingerprint, $scopes) =
            @{$m->get_token_details($token)}{qw/loginid creation_time ua_fingerprint scopes/};
        return unless $loginid;
        $epoch = Date::Utility->new($creation_time)->epoch if $creation_time;
    } else {
        # invalid token type
        return;
    }

    return {
        loginid        => $loginid,
        scopes         => $scopes,
        epoch          => $epoch,
        ua_fingerprint => $ua_fingerprint,
        ($valid_for_ip) ? (valid_for_ip => $valid_for_ip) : (),
    };
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

=head2 invalid_params
pa parameters are allowed when the type provided is paymentagent_withdraw.
invalid_params returns an error when the client declare pa params for other types.
=cut

sub invalid_params {
    return create_error({
        code              => 'InvalidParameters',
        message_to_client => 'pa parameters are valid from paymentagent_withdraw only'
    });
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

sub client_error() {
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

sub is_verification_token_valid {
    my ($token, $email, $created_for) = @_;

    my $verification_token = BOM::Platform::Token->new({token => $token});
    my $response           = create_error({
            code              => "InvalidToken",
            message_to_client => localize('Your token has expired or is invalid.')});

    return $response unless ($verification_token and $verification_token->token);

    unless ($verification_token->{created_for} eq $created_for) {
        $verification_token->delete_token;
        return $response;
    }

    if ($verification_token->email and $verification_token->email eq $email) {
        $response = {status => 1};
    }
    $verification_token->delete_token;

    return $response;
}

sub check_password {
    my $args = shift;

    my $email        = $args->{email};
    my $new_password = $args->{new_password};

    if (exists $args->{old_password} && exists $args->{user_pass}) {
        my $old_password = $args->{old_password};
        my $user_pass    = $args->{user_pass};

        return BOM::RPC::v3::Utility::create_error({
                code              => 'PasswordError',
                message_to_client => localize('Provided password is incorrect.')}) if (not BOM::User::Password::checkpw($old_password, $user_pass));

        return BOM::RPC::v3::Utility::create_error({
                code              => 'PasswordError',
                message_to_client => localize('Current password and new password cannot be the same.')}) if ($new_password eq $old_password);
    }

    return BOM::RPC::v3::Utility::create_error({
            code              => 'PasswordError',
            message_to_client =>
                localize('Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.')}
    ) if $new_password !~ REGEX_PASSWORD_VALIDATION;

    return BOM::RPC::v3::Utility::create_error({
            code              => 'PasswordError',
            message_to_client => localize('You cannot use your email address as your password.')}) if lc $new_password eq lc $email;

    return undef;
}

=head2 validate_mt5_password
    Validates the mt5 password must be of 8-25 characters long.
    It must also have at least 1 character of each uppercase letters, lowercase letters, and numbers.
    Returns error message code if check fails else undef.
=cut

sub validate_mt5_password {
    my $args       = shift;
    my $email      = $args->{email};
    my $invest_pwd = $args->{invest_password};
    my $main_pwd   = $args->{main_password};

    if (defined $main_pwd) {
        return 'IncorrectMT5PasswordFormat'    if $main_pwd !~ REGEX_PASSWORD_VALIDATION;
        return 'MT5PasswordEmailLikenessError' if lc $main_pwd eq lc $email;
    }

    if (defined $invest_pwd) {
        return 'IncorrectMT5PasswordFormat'    if $invest_pwd && $invest_pwd !~ REGEX_PASSWORD_VALIDATION;    # invest password can also be empty.
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
        'email unverified'     => localize('Your email address is unverified.'),
        'no residence'         => localize('Your account has no country of residence.'),
        'invalid'              => localize('Sorry, account opening is unavailable.'),
        'InvalidAccount'       => localize('Sorry, account opening is unavailable.'),
        'invalid residence'    => localize('Sorry, our service is not available for your country of residence.'),
        'InvalidAccountRegion' => localize('Sorry, account opening is unavailable in your region.'),
        'PostcodeRequired'     => localize('Postcode is required for UK residents.'),
        'PoBoxInAddress'       => localize('P.O. Box is not accepted in address.'),
        'duplicate email'      => localize(
            'Your provided email address is already in use by another Login ID. According to our terms and conditions, you may only register once through our site.'
        ),
        'DuplicateVirtualWallet' => localize('Sorry, a virtual wallet account already exists. Only one virtual wallet account is allowed.'),
        'duplicate name DOB'     =>
            localize('Sorry, it looks like you already have a real money account with us. Only one real money account is allowed for each client.'),
        'too young'            => localize('Sorry, you are too young to open an account.'),
        'show risk disclaimer' => localize('Please agree to the risk disclaimer before proceeding.'),
        'insufficient score'   => localize(
            'Unfortunately your answers to the questions above indicate that you do not have sufficient financial resources or trading experience to be eligible to open a trading account at this time.'
        ),
        'InvalidDateOfBirth'         => localize('Date of birth is invalid.'),
        'InvalidPlaceOfBirth'        => localize('Please enter a valid place of birth.'),
        'InsufficientAccountDetails' => localize('Please provide complete details for your account.'),
        'InvalidCitizenship'         => localize('Sorry, our service is not available for your country of citizenship.'),
        'InvalidResidence'           => localize('Sorry, our service is not available for your country of residence.'),
        'InvalidDateFirstContact'    => localize('Date first contact is invalid.'),
        'InvalidBrand'               => localize('Brand is invalid.'),
        'CannotChangeAccountDetails' => localize('You may not change these account details.'),
        'UnwelcomeAccount'           => localize('We are unable to do that because your account has been restricted. If you need help, let us know.'),
        'InvalidPhone'               => localize('Please enter a valid phone number, including the country code (e.g. +15417541234).'),
        'NeedBothSecret'             => localize('Need both secret question and secret answer.'),
        'DuplicateAccount' => localize('Sorry, an account already exists with those details. Only one real money account is allowed per client.'),
        'DuplicateWallet'  => localize('Sorry, a wallet already exists with those details.'),
        'BelowMinimumAge'  => localize('Value of date of birth is below the minimum age required.'),
        'FinancialAccountExists'     => localize('You already have a financial money account. Please switch accounts to trade financial products.'),
        'NewAccountLimitReached'     => localize('You have created all accounts available to you.'),
        'NoResidence'                => localize('Please set your country of residence.'),
        'SetExistingAccountCurrency' => localize('Please set the currency for your existing account [_1], in order to create more accounts.'),
        'P2PRestrictedCountry'       => localize("Deriv P2P is unavailable in your country. Please provide a different account opening reason."),
        'InputValidationFailed'      => localize("This field is required."),

        # validate_paymentagent_details
        'RequiredFieldMissing'       => localize('This field is required.'),
        'NoAccountCurrency'          => localize('Please set the currency for your existing account.'),
        'PaymentAgentsSupended'      => localize('Payment agents are suspended in your residence country.'),
        'DuplicateName'              => localize('You cannot use this name, because it is taken by someone else.'),
        'MinWithdrawalIsNegative'    => localize('The requested minimum amount must be greater than zero.'),
        'MaxWithdrawalIsLessThanMin' => localize('The requested maximum amount must be greater than minimum amount.'),
        'ValueOutOfRange'            => localize('It must be between [_1] and [_2].'),
        'CodeOfConductNotApproved'   => localize('Code of conduct should be accepted.'),
        'TooManyDecimalPlaces'       => localize('Only [_1] decimal places are allowed.'),
        'InvalidNumericValue'        => localize('The numeric value is invalid.'),
        'InvalidStringValue'         => localize('This field must contain at least one alphabetic character.'),

        'DuplicateCurrency'        => localize("Please note that you are limited to only one [_1] account."),
        'CannotChangeWallet'       => localize("Sorry, your trading account is already linked to a wallet."),
        'CurrencyMismatch'         => localize("Please ensure your trading account currency is the same as your wallet account currency."),
        'CannotLinkWallet'         => localize("Sorry, we couldn't link your trading account to this wallet."),
        'InvalidWalletAccount'     => localize("Sorry, we couldn't find your wallet account."),
        'InvalidMT5Account'        => localize("Sorry, we couldn't find your MT5 account."),
        'DXInvalidAccount'         => localize("Sorry, we couldn't find your DXTrader account."),
        'InvalidTradingAccount'    => localize("Sorry, we couldn't find your trading account."),
        'CannotLinkVirtualAndReal' => localize("Please ensure your trading account type is the same as your wallet account type."),
        'ForbiddenPostcode'        =>
            localize("Our services are not available for your country of residence. Please see our terms and conditions for more information."),

        'CurrencySuspended'      => localize("The provided currency [_1] is not selectable at the moment."),
        'InvalidCryptoCurrency'  => localize("The provided currency [_1] is not a valid cryptocurrency."),
        'ExperimentalCurrency'   => localize("This currency is temporarily suspended. Please select another currency to proceed."),
        'DuplicateWallet'        => localize('Sorry, a wallet already exists with those details.'),
        'MT5AccountExisting'     => localize('Change of currency is not allowed due to an existing MT5 account.'),
        'AccountWithDeposit'     => localize('Change of currency is not allowed for an existing account with previous deposits.'),
        'CryptoAccount'          => localize('Account currency is set to cryptocurrency. Any change is not allowed.'),
        'CurrencyNotApplicable'  => localize('The provided currency [_1] is not applicable for this account.'),
        'CurrencyNotAllowed'     => localize("The provided currency [_1] is not selectable at the moment."),
        'CurrencyTypeNotAllowed' => localize('Please note that you are limited to one fiat currency account.'),

        'CurrencySuspended'     => localize("The provided currency [_1] is not selectable at the moment."),
        'InvalidCryptoCurrency' => localize("The provided currency [_1] is not a valid cryptocurrency."),
        'ExperimentalCurrency'  => localize("This currency is temporarily suspended. Please select another currency to proceed."),
        'DuplicateWallet'       => localize('Sorry, a wallet already exists with those details.'),
        'AllowCopiersError'     => localize("Copier can't be a trader."),
        'TaxInformationCleared' => localize('Tax information cannot be removed once it has been set.'),
        'TINDetailsMandatory'   =>
            localize('Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.'),
        'ProfessionalNotAllowed'        => localize('Professional status is not applicable to your account.'),
        'ProfessionalAlreadySubmitted'  => localize('You already requested professional status.'),
        'IncompleteFinancialAssessment' => localize("The financial assessment is not complete"),

        'SelfExclusion' => localize(
            'Sorry, but you have self-excluded yourself from the website until [_1]. If you are unable to place a trade or deposit after your self-exclusion period, please contact the Customer Support team for assistance.'
        ),
        'SetSelfExclusionError' => localize('Sorry, but setting your maximum deposit limit is unavailable in your country.'),
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
    my $legal_allowed_currencies = LandingCompany::Registry::get($landing_company_name)->legal_allowed_currencies;

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
        to      => $brand->emails('compliance'),
        subject => "$loginid requested for professional status, residence: " . ($residence // 'No residence provided'),
        message => ["$loginid has requested for professional status, please check and update accordingly"],
    });
}

=head2 _timed

Helper function for recording time elapsed via statsd.

=cut

sub _timed(&@) {    ## no critic (ProhibitSubroutinePrototypes)
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
    my @currencies           = keys %{LandingCompany::Registry::get($landing_company_name)->legal_allowed_currencies};

    my $suspended_currencies = BOM::Config::CurrencyConfig::get_suspended_crypto_currencies();

    my @valid_payout_currencies =
        sort grep { !exists $suspended_currencies->{$_} } @currencies;
    return \@valid_payout_currencies;
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
    my ($error, $orverride_code) = @_;

    # For scalar errors (without error code, etc) let it be caught and logged by default RPC error handling.
    die $error unless (ref $error and ($error->{code} // $error->{error_code}));    # refactor this later to accept error_code only.

    my $error_code = $error->{code} // $error->{error_code};

    my $message;
    $message = $ImmutableFieldError{$error->{details}->{field}} // ''
        if $error_code eq 'ImmutableFieldChanged' && $error->{details}->{field};

    return create_error_by_code(
        $error_code, %$error,
        message_to_client => $message,
        override_code     => $orverride_code
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

    my $message_to_client = $options{message_to_client} // error_map()->{$error_code};
    return BOM::RPC::v3::Utility::permission_error() unless $message_to_client;

    if ($options{params}) {
        my @params = ref $options{params} eq 'ARRAY' ? @{$options{params}} : ($options{params});
        $message_to_client = localize($message_to_client, @params);
    }

    return BOM::RPC::v3::Utility::create_error({
            code              => $options{override_code} ? $options{override_code} : $error_code,
            message_to_client => $message_to_client,
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

=item * C<source_bypass_verification>: boolean, whether to skip the doughflow deposits check for payment agent withdraw

=back

Returns an RPC error structure, or undef if no error.

=cut

sub cashier_validation {
    my ($client, $type, $source_bypass_verification) = @_;

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

    if ($type eq 'paymentagent_withdraw') {
        my $app_config = BOM::Config::Runtime->instance->app_config;

        return $error_sub->(localize('Sorry, this facility is temporarily disabled due to system maintenance.'))
            if ($app_config->system->suspend->payment_agents);

        return $error_sub->(localize('Payment agent facilities are not available for this account.'))
            unless $client->landing_company->allows_payment_agents;

        return $error_sub->(localize('You are not authorized for withdrawals via payment agents.'))
            unless ($source_bypass_verification
            or BOM::Transaction::Validation->new({clients => [$client]})->allow_paymentagent_withdrawal($client));
    }

    my $validation_type = $type =~ /^(payment_withdraw|paymentagent_withdraw)$/ ? 'withdraw' : $type;
    my $validation      = BOM::Platform::Client::CashierValidation::validate($client->loginid, $validation_type, $error_code);
    return create_error($validation->{error}) if exists $validation->{error};

    return;
}

=head2 set_trading_password_new_account

Validates or sets the user trading password when creating a new trading accout.

=over 4

=item * C<client>: C<BOM::User::Client> object

=item * C<trading_password>: plain password

=back

Returns scalar error code.

=cut

sub set_trading_password_new_account {
    my ($client, $trading_password) = @_;

    return 'PasswordRequired' unless $trading_password;

    if (my $current_password = $client->user->trading_password) {
        return validate_password_with_attempts($trading_password, $current_password, $client->loginid);
    } else {
        my $error = check_password({
            email        => $client->email,
            new_password => $trading_password,
        });
        die $error->{error} if $error;

        $client->user->update_trading_password($trading_password);
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

1;
