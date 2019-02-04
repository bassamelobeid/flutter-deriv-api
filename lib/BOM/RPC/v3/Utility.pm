
=head1 BOM::RPC::v3::Utility

Utility package for BOM::RPC::v3

=cut

package BOM::RPC::v3::Utility;

use strict;
use warnings;

use utf8;

no indirect;

use Try::Tiny;
use Date::Utility;
use YAML::XS qw(LoadFile);
use List::Util qw(any uniqstr shuffle);
use List::UtilsBy qw(bundle_by);
use JSON::MaybeXS qw{encode_json};
use URI;
use Domain::PublicSuffix;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc stats_gauge);
use Time::HiRes;
use Time::Duration::Concise::Localize;
use Format::Util::Numbers qw/formatnumber/;
use JSON::MaybeUTF8 qw/encode_json_utf8/;

use Brands;
use Quant::Framework;
use LandingCompany::Registry;
use Finance::Contract::Longcode qw(shortcode_to_longcode);
use LandingCompany::Registry;

use BOM::Platform::Context qw(localize request);
use BOM::Platform::ProveID;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Config::RedisReplicated;
use BOM::Config::Runtime;
use BOM::Database::Model::AccessToken;
use BOM::Database::Model::OAuth;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Token;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Client::CashierValidation;
use BOM::MarketData qw(create_underlying);

use Exporter qw(import export_to_level);
our @EXPORT_OK = qw(longcode);

use feature "state";

# Number of keys to get/set per batch in Redis
use constant LONGCODE_REDIS_BATCH => 20;

# Seconds between reloads of the rate_limitations.yml file.
# We don't want to reload too frequently, since we may see a lot of `website_status` calls.
# However, it's a config file held outside the repo, so we also don't want to let it get too old.
use constant RATES_FILE_CACHE_TIME => 120;

# Maximum values for contract durations; larger ones can cause timeouts/warnings in Date::Utility
my %DURATION_LIMITS = (
    d => 365,
    h => 168,     # 1 week
    m => 1440,    # 1 day
    s => 3600,    # 1 hour
    t => 10
);

# For transfers, defines the oldest rates allowed for currency conversion per currency type
use constant CURRENCY_CONVERSION_MAX_AGE_FIAT   => 3600 * 24;    # 1 day
use constant CURRENCY_CONVERSION_MAX_AGE_CRYPTO => 3600;

=head2 transaction_validation_checks

    my $error = transaction_validation_checks($client, qw(check_trade_status check_tax_information));

Performs a list of given Transaction Validation checks in addtion to C<validate_tnc> and C<compliance_checks> for a given client.
Returns an error if a check fails else undef.

=cut

sub transaction_validation_checks {
    my ($client, @validations) = @_;
    return validation_checks($client, qw(validate_tnc compliance_checks), @validations);
}

=head2 validation_checks

    my $error = validation_checks($client, qw(validate_tnc check_trade_status check_tax_information));

Performs a list of given Transaction Validation checks for a given client.
Returns an error if a check fails else undef.

=cut

sub validation_checks {
    my ($client, @validations) = @_;

    for my $act (@validations) {
        die "Error: no such hook $act" unless BOM::Transaction::Validation->can($act);

        my $err;
        try {
            $err = BOM::Transaction::Validation->new({clients => $client})->$act($client);
        }
        catch {
            warn "Error happened when call before_action $act";
            $err = Error::Base->cuss({
                -type              => 'Internal Error',
                -mesg              => 'Internal Error',
                -message_to_client => localize('Sorry, there is an internal error.'),
            });
        };

        return BOM::RPC::v3::Utility::create_error({
                code              => $err->get_type,
                message_to_client => $err->{-message_to_client},
            }) if defined $err and ref $err eq "Error::Base";
    }

    return undef;
}

sub contract_args_check {
    my $args = shift;

    my $duration_unit = $args->{duration_unit} ? lc $args->{duration_unit} : '';

    return invalid_duration() if ($args->{duration} // 0) > ($DURATION_LIMITS{$duration_unit} // 'inf');

    return undef;
}

sub get_suspended_crypto_currencies {
    my @suspended_currencies = split /,/, BOM::Config::Runtime->instance->app_config->system->suspend->cryptocurrencies;
    s/^\s+|\s+$//g for @suspended_currencies;

    my %suspended_currencies_hash = map { $_ => 1 } @suspended_currencies;

    return \%suspended_currencies_hash;
}

sub get_token_details {
    my $token = shift;

    return unless $token;

    my ($loginid, $creation_time, $epoch, $ua_fingerprint, $scopes, $valid_for_ip);
    if (length $token == 15) {    # access token
        my $m = BOM::Database::Model::AccessToken->new;
        ($loginid, $creation_time, $scopes, $valid_for_ip) = @{$m->get_token_details($token)}{qw/loginid creation_time scopes valid_for_ip/};
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

sub create_error {
    my $args = shift;
    stats_inc("bom_rpc.v_3.error", {tags => ['code:' . $args->{code},]});
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
    return create_error({
            code              => 'PermissionDenied',
            message_to_client => localize('Permission denied.')});
}

sub invalid_email {
    return create_error({
            code              => 'InvalidEmail',
            message_to_client => localize('This email address is invalid.')});
}

sub invalid_duration {
    return create_error({
            code              => 'OfferingsValidationError',
            message_to_client => localize('Trading is not offered for this duration.')});
}

# Start this at zero to ensure we always load on first call.
my $rates_file_last_load = 0;
my $rates_file_content;

sub site_limits {
    my $now = time;
    if ($now - $rates_file_last_load > RATES_FILE_CACHE_TIME) {
        $rates_file_content = LoadFile($ENV{BOM_TEST_RATE_LIMITATIONS} // '/etc/rmg/perl_rate_limitations.yml');
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
            message_to_client => localize('Sorry, an error occurred while processing your account.')});
}

sub website_name {
    my $server_name = shift;

    return "Binary$server_name.com" if ($server_name =~ /^qa\d+$/);

    return Brands->new(name => request()->brand)->website_name;
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
    my $response = create_error({
            code              => "InvalidToken",
            message_to_client => localize('Your token has expired or is invalid.')});

    return $response unless ($verification_token and $verification_token->token);

    unless ($verification_token->{created_for} eq $created_for) {
        $verification_token->delete_token;
        return $response;
    }

    if ($verification_token->email and $verification_token->email eq $email) {
        $response = {status => 1};
    } else {
        $response = create_error({
                code              => 'InvalidEmail',
                message_to_client => localize('Email address is incorrect.')});
    }
    $verification_token->delete_token;

    return $response;
}

sub _check_password {
    my $args         = shift;
    my $new_password = $args->{new_password};
    if (keys %$args == 3) {
        my $old_password = $args->{old_password};
        my $user_pass    = $args->{user_pass};

        return BOM::RPC::v3::Utility::create_error({
                code              => 'PasswordError',
                message_to_client => localize('Old password is wrong.')}) if (not BOM::User::Password::checkpw($old_password, $user_pass));

        return BOM::RPC::v3::Utility::create_error({
                code              => 'PasswordError',
                message_to_client => localize('New password is same as old password.')}) if ($new_password eq $old_password);
    }

    return BOM::RPC::v3::Utility::create_error({
            code              => 'PasswordError',
            message_to_client => localize('Password should be at least six characters, including lower and uppercase letters with numbers.')}
    ) if (length($new_password) < 6 or $new_password !~ /[0-9]+/ or $new_password !~ /[a-z]+/ or $new_password !~ /[A-Z]+/);

    return;
}

sub login_env {
    my $params = shift;

    my $now                = Date::Utility->new->datetime_ddmmmyy_hhmmss_TZ;
    my $ip_address         = $params->{client_ip} || '';
    my $ip_address_country = $params->{country_code} ? uc $params->{country_code} : '';
    my $lang               = $params->{language} ? uc $params->{language} : '';
    my $ua                 = $params->{user_agent} || '';
    my $environment        = "$now IP=$ip_address IP_COUNTRY=$ip_address_country User_AGENT=$ua LANG=$lang";
    return $environment;
}

sub mask_app_id {
    my ($id, $time) = @_;

    # this is the date when we started populating source with app_id, before this
    # there were random numbers so don't want to send them back
    $id = undef if ($time and Date::Utility->new($time)->is_before(Date::Utility->new("2016-03-01")));

    return $id;
}

sub error_map {
    return {
        'email unverified'    => localize('Your email address is unverified.'),
        'no residence'        => localize('Your account has no country of residence.'),
        'invalid'             => localize('Sorry, account opening is unavailable.'),
        'invalid residence'   => localize('Sorry, our service is not available for your country of residence.'),
        'invalid UK postcode' => localize('Postcode is required for UK residents.'),
        'invalid PO Box'      => localize('P.O. Box is not accepted in address.'),
        'invalid DOB'         => localize('Your date of birth is invalid.'),
        'duplicate email'     => localize(
            'Your provided email address is already in use by another Login ID. According to our terms and conditions, you may only register once through our site.'
        ),
        'duplicate name DOB' => localize(
            'Sorry, you seem to already have a real money account with us. Perhaps you have used a different email address when you registered it. For legal reasons we are not allowed to open multiple real money accounts per person.'
        ),
        'too young'            => localize('Sorry, you are too young to open an account.'),
        'show risk disclaimer' => localize('Please agree to the risk disclaimer before proceeding.'),
        'insufficient score'   => localize(
            'Unfortunately your answers to the questions above indicate that you do not have sufficient financial resources or trading experience to be eligible to open a trading account at this time.'
        ),
        'InvalidDateOfBirth'         => localize('Date of birth is invalid'),
        'InsufficientAccountDetails' => localize('Please provide complete details for account opening.'),
        'InvalidCitizenship'         => localize('Sorry, our service is not available for your country of citizenship.'),
        'InvalidDateFirstContact'    => localize('Date first contact is invalid.'),
        'InvalidBrand'               => localize('Brand is invalid.')};
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

=head2 validate_make_new_account

    validate_make_new_account($client, $account_type, $request_data)

    Make several checks based on $client and $account type.
    Updates $request_data(hashref) with $client's sensitive data.

=cut

sub validate_make_new_account {
    my ($client, $account_type, $request_data) = @_;

    return permission_error() if (not $account_type and $account_type !~ /^(?:real|financial)$/);

    my $residence = $client->residence;
    return create_error({
            code              => 'NoResidence',
            message_to_client => localize('Please set your country of residence.')}) unless $residence;

    my $countries_instance = Brands->new(name => request()->brand)->countries_instance;
    my $gaming_company     = $countries_instance->gaming_company_for_country($residence);
    my $financial_company  = $countries_instance->financial_company_for_country($residence);

    my $error_map = error_map();
    return create_error({
            code              => 'InvalidAccount',
            message_to_client => $error_map->{'invalid'}}) unless ($gaming_company or $financial_company);

    return create_error({
            code              => 'InvalidResidence',
            message_to_client => $error_map->{'invalid residence'}}) if ($countries_instance->restricted_country($residence));

    if ($client->is_virtual && $account_type eq 'financial' && $gaming_company && ($financial_company // '') eq 'maltainvest') {
        # if the gaming_company is none this means that the user can create an maltainvest account without
        # needs to create an MX account first from an virtual account.
        # if the gaming_company has some data, the client needs first create the gaming account and after that
        # create the financial account, can't create the financial account from the virtual account directly.
        return permission_error();
    }

    # get all real account siblings
    my $siblings = $client->real_account_siblings_information;

    # if no real sibling is present then its virtual
    if (scalar(keys %$siblings) == 0) {
        if ($account_type eq 'real') {
            return undef if $gaming_company;
            # send error as account opening for maltainvest has separate call
            return create_error({
                    code              => 'InvalidAccount',
                    message_to_client => $error_map->{'invalid'}}) if ($financial_company and any { $_ eq $financial_company } qw(maltainvest));
        } elsif ($account_type eq 'financial' and ($financial_company and $financial_company ne 'maltainvest')) {
            return create_error({
                    code              => 'InvalidAccount',
                    message_to_client => $error_map->{'invalid'}});
        }

        # some countries don't have gaming company like Singapore
        # but we do allow them to open only financial account
        return undef;
    }

    my $landing_company_name = $client->landing_company->short;

    # as maltainvest can be opened in few ways, upgrade from malta,
    # directly from virtual for Germany as residence, from iom
    # or from maltainvest itself as we support multiple account now
    # so upgrade is only allow once
    if (($account_type and $account_type eq 'financial') and $landing_company_name =~ /^(?:malta|iom)$/) {
        # return error if client already has maltainvest account
        return create_error({
                code              => 'FinancialAccountExists',
                message_to_client => localize('You already have a financial money account. Please switch accounts to trade financial products.')}
        ) if (grep { $siblings->{$_}->{landing_company_name} eq 'maltainvest' } keys %$siblings);

        return create_error({
                code              => 'UnwelcomeAccount',
                message_to_client => localize('You cannot perform this action, as your account [_1] is marked as unwelcome.', $client->loginid)}
        ) if $client->status->unwelcome;

        # if from malta and account type is maltainvest, assign
        # maltainvest to landing company as client is upgrading
        $landing_company_name = 'maltainvest';
    }

    if ($client->is_virtual) {
        my @landing_company_clients;
        if ($account_type eq 'real') {
            @landing_company_clients = $client->user->clients_for_landing_company($gaming_company);
        } else {
            @landing_company_clients = $client->user->clients_for_landing_company($financial_company);
        }

        return permission_error() if (any { not $_->status->duplicate_account } @landing_company_clients);
    } else {
        # we have real account, and going to create another one
        # So, lets populate all sensitive data from current client, ignoring provided input
        # this logic should gone after we separate new_account with new_currency for account
        foreach (qw/first_name last_name residence address_city phone date_of_birth address_line_1/) {
            $request_data->{$_} = $client->$_;
        }
    }

    my $error = create_error({
            code              => 'NewAccountLimitReached',
            message_to_client => localize('You have created all accounts available to you.')});

    # filter siblings by landing company as we don't want to check cross
    # landing company siblings, for example MF should check only its
    # corresponding siblings not MLT one
    $siblings = filter_siblings_by_landing_company($landing_company_name, $siblings);

    # return if any one real client has not set account currency
    if (my ($loginid_no_curr) = grep { not $siblings->{$_}->{currency} } keys %$siblings) {
        return create_error({
                code => 'SetExistingAccountCurrency',
                message_to_client =>
                    localize('Please set the currency for your existing account [_1], in order to create more accounts.', $loginid_no_curr)});
    }

    if ($request_data->{currency}) {
        my $is_currency_allowed = _is_currency_allowed($client, $siblings, $request_data->{currency});
        return _currency_type_error($is_currency_allowed->{message}) unless $is_currency_allowed->{allowed};
    }

    # check if all currencies are exhausted i.e.
    # - if client has one type of fiat currency don't allow them to open another
    # - if client has all of allowed cryptocurrency
    my @available_currencies = get_available_currencies($siblings, $landing_company_name);

    # Check if client can create anymore accounts, if currency is available. Otherwise, return error
    return $error unless @available_currencies;

    return undef;
}

sub validate_set_currency {
    my ($client, $currency) = @_;

    my $siblings = $client->real_account_siblings_information();
    $siblings = filter_siblings_by_landing_company($client->landing_company->short, $siblings);

    my $is_currency_allowed = _is_currency_allowed($client, $siblings, $currency);
    return _currency_type_error($is_currency_allowed->{message}) unless $is_currency_allowed->{allowed};

    return undef;
}

sub _currency_type_error {
    my $message = shift;
    return create_error({
            code              => 'CurrencyTypeNotAllowed',
            message_to_client => localize($message)});
}

sub _is_currency_allowed {
    my $client   = shift;
    my $siblings = shift;
    my $currency = shift;

    my $type = LandingCompany::Registry::get_currency_type($currency);

    my $result = {
        allowed => 0,
        message => localize("The provided currency [_1] is not applicable for this account.", $currency),
    };

    return $result unless $client->landing_company->is_currency_legal($currency);

    my $error;
    $error = try {
        return localize("The provided currency [_1] is not selectable at the moment.", $currency)
            if ($type eq 'crypto' and BOM::Platform::Client::CashierValidation::is_crypto_currency_suspended($currency));
    }
    catch {
        return localize("The provided currency [_1] is not a valid cryptocurrency.", $currency);
    };
    if ($error) {
        $result->{message} = $error;
        return $result;
    }

    #that's enough for virtual accounts or empty siblings
    return {allowed => 1} if ($client->is_virtual or scalar(keys %$siblings) == 0);

    # if fiat then check if client has already any fiat, if yes then don't allow
    $result->{message} = localize('Please note that you are limited to one fiat currency account.');
    return $result
        if ($type eq 'fiat'
        and grep { (LandingCompany::Registry::get_currency_type($siblings->{$_}->{currency}) // '') eq 'fiat' } keys %$siblings);

    # if crypto check if client has same crypto, if yes then don't allow
    $result->{message} = localize("Please note that you are limited to only one [_1] account.", $currency);
    return $result if ($type eq 'crypto' and grep { $currency eq ($siblings->{$_}->{currency} // '') } keys %$siblings);

    # if currency is experimental and client is not allowed to use such currencies we don't allow
    my $allowed_emails = BOM::Config::Runtime->instance->app_config->payments->experimental_currencies_allowed;
    my $client_email   = $client->email;
    $result->{message} = localize('Please note that the selected currency is allowed for limited accounts only');

    return $result
        if (LandingCompany::Registry::get_currency_definition($currency)->{experimental}
        and not any { $_ eq $client_email } @$allowed_emails);

    $result->{allowed} = 1;

    return $result;
}

sub validate_uri {
    my $original_url = shift;
    my $url          = URI->new($original_url);

    if ($original_url =~ /[^[:ascii:]]/) {
        return localize('Unicode is not allowed in URL');
    }
    if (not defined $url->scheme or ($url->scheme ne 'http' and $url->scheme ne 'https')) {
        return localize('The given URL is not http(s)');
    }
    if ($url->userinfo) {
        return localize('URL should not have user info');
    }
    if ($url->port != 80 && $url->port != 443) {
        return localize('Only ports 80 and 443 are allowed');
    }
    if ($url->fragment) {
        return localize('URL should not have fragment');
    }
    if ($url->query) {
        return localize('URL should not have query');
    }
    my $host = $url->host;
    if (!$host || $original_url =~ /https?:\/\/.*(\:|\@|\#|\?)+/) {
        return localize('Invalid URL');
    }
    my $suffix = Domain::PublicSuffix->new();
    if (!$suffix->get_root_domain($host)) {
        return localize('Unknown domain name');
    }

    return undef;
}

sub set_professional_status {
    my ($client, $professional, $professional_requested) = @_;
    my $error;

    # Set checks in variables
    my $cr_mf_valid      = $client->landing_company->short =~ /^(?:costarica|maltainvest)$/;
    my $set_prof_status  = $professional && !$client->status->professional && $cr_mf_valid;
    my $set_prof_request = $professional_requested && !$client->status->professional_requested && $cr_mf_valid;

    try {
        $client->status->set('professional',           'SYSTEM', 'Mark as professional as requested') if $set_prof_status;
        $client->status->set('professional_requested', 'SYSTEM', 'Professional account requested')    if $set_prof_request;
    }
    catch { $error = client_error() };
    return $error if $error;

    send_professional_requested_email($client->loginid, $client->residence, $client->landing_company->short) if $set_prof_request;

    return undef;
}

sub send_professional_requested_email {
    my ($loginid, $residence, $landing_company_short) = @_;

    return unless $loginid;

    my $brand = Brands->new(name => request()->brand);

    my $to_email = $brand->emails('compliance');

    # Notify customer support for non-CR clients who requested for professional status
    $to_email .= ',' . $brand->emails('support') if ($landing_company_short ne 'costarica');

    return send_email({
        from    => $brand->emails('support'),
        to      => $to_email,
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
    }
    catch {
        $exception = $_;
        $k .= '.error';
    };
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
    die 'Invalid currency: ' . $params->{currency} unless ((uc $params->{currency}) =~ /^[A-Z]{3}$/);

    # We generate a hash, so we only need each shortcode once
    my @short_codes = uniqstr(@{$params->{short_codes}});
    my %longcodes;
    foreach my $shortcode (@short_codes) {
        try {
            $longcodes{$shortcode} = localize(shortcode_to_longcode($shortcode, $params->{currency}));
        }
        catch {
            # we do not want to warn for known error like legacy underlying
            if ($_ !~ /unknown underlying/) {
                warn "exception is thrown when executing shortcode_to_longcode, parameters: " . $shortcode . ' error: ' . $_;
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

    my $suspended_currencies = get_suspended_crypto_currencies();

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
    my $redis = BOM::Config::RedisReplicated::redis_write;
    use constant REDIS_MASTERKEY => 'IP_COUNTRY_MISMATCH';

    return undef unless $data{country_code};

    if (uc($data{client_residence}) ne uc($data{country_code})) {
        my $json_record = encode_json({
                date_time        => Date::Utility->new()->datetime_ddmmmyy_hhmmss_TZ(),
                client_residence => uc $data{client_residence},
                ip_address       => $data{client_ip},
                ip_country       => uc $data{country_code},
                broker_code      => $data{broker_code}});
        $redis->hset(REDIS_MASTERKEY, $data{client_login_id} => $json_record);
    }

    return undef;
}

1;
