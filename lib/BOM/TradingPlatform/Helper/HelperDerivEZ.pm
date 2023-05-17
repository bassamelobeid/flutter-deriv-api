package BOM::TradingPlatform::Helper::HelperDerivEZ;

use strict;
use warnings;
no indirect;

use Digest::SHA            qw(sha384_hex);
use BOM::Platform::Context qw (localize request);
use LandingCompany::Registry;
use BOM::Config::Runtime;
use BOM::MT5::User::Async;
use BOM::Config;
use DataDog::DogStatsd::Helper qw/stats_inc stats_event/;
use List::Util                 qw(all any first);
use Format::Util::Numbers      qw(formatnumber financialrounding);
use Syntax::Keyword::Try;
use BOM::Platform::Event::Emitter;
use ExchangeRates::CurrencyConverter qw/convert_currency offer_to_clients/;
use BOM::User::Utility               qw(parse_mt5_group);
use Log::Any                         qw($log);
use BOM::User::FinancialAssessment;

use base 'Exporter';
our @EXPORT_OK = qw(
    new_account_trading_rights
    create_error
    validate_new_account_params
    validate_user
    generate_password
    is_account_demo
    is_restricted_group
    get_landing_company
    derivez_group
    do_derivez_deposit
    is_derivez
    get_derivez_prefix
    get_derivez_account_type_config
    derivez_accounts_lookup
    set_deriv_prefix_to_mt5
    payment_agent_trading_rights
    affiliate_trading_rights
    is_identical_group
    derivez_validate_and_get_amount
    record_derivez_transfer_to_mt5_transfer
    send_transaction_email
    do_derivez_withdrawal
    get_derivez_landing_company
    get_loginid_number
);

use constant USER_RIGHT_ENABLED        => 0x0000000000000001;
use constant USER_RIGHT_TRAILING       => 0x0000000000000020;
use constant USER_RIGHT_EXPERT         => 0x0000000000000040;
use constant USER_RIGHT_API            => 0x0000000000000080;
use constant USER_RIGHT_REPORTS        => 0x0000000000000100;
use constant USER_RIGHT_TRADE_DISABLED => 0x0000000000000004;

# For now it's only available for sinle landing company.
# if we'll need to add more companies, then better to move to landing company configuration
use constant DERIVEZ_AVAILABLE_FOR => 'svg';

=head1 NAME 

BOM::TradingPlatform::Helper::HelperDerivEZ

=head1 SYNOPSIS 

Helper module for derivez implementation

=cut

=head2 new_account_trading_rights

Returns the DerivEZ new account permissions

=cut

sub new_account_trading_rights {
    return USER_RIGHT_ENABLED | USER_RIGHT_TRAILING | USER_RIGHT_EXPERT | USER_RIGHT_API | USER_RIGHT_REPORTS;
}

=head2 payment_agent_trading_rights

Returns the DerivEZ payment agent trading permissions

=cut

sub payment_agent_trading_rights {
    return USER_RIGHT_ENABLED | USER_RIGHT_TRAILING | USER_RIGHT_EXPERT | USER_RIGHT_API | USER_RIGHT_REPORTS | USER_RIGHT_TRADE_DISABLED;
}

=head2 affiliate_trading_rights

Returns the DerivEZ affiliate trading permissions

=cut

sub affiliate_trading_rights {
    return USER_RIGHT_TRADE_DISABLED;
}

=head2 create_error

Returns future fail

=cut

my $error_handler = sub {
    my $err = shift;

    if (ref $err eq 'HASH' and $err->{code}) {
        return create_error($err->{code}, {message => $err->{error}});
    } else {
        return $err;
    }
};

sub create_error {
    my ($error_code, $details, @extra) = @_;

    my $error_registry = BOM::RPC::v3::MT5::Errors->new();
    if (ref $details eq 'HASH' and ref $details->{message} eq 'HASH') {
        return {$details->{message}};
    }
    return $error_registry->format_error($error_code, $details, @extra);

}

=head2 validate_new_account_params

Validate the parameters for DerivEZ new account creation
Return future fail for any failed validation

=cut

sub validate_new_account_params {
    my (%args) = @_;

    if ($args{company} eq 'none') {
        return 'DerivezNotAllowed';
    }

    return 'InvalidAccountType' if (not $args{account_type} or $args{account_type} !~ /^demo|real$/);
    return 'InvalidMarketType'  if (not $args{market_type}  or $args{market_type}  !~ /^all$/);
    return 'InvalidPlatform'    if $args{platform} ne 'derivez';

    return;
}

=head2 validate_user

Validate the user for DerivEZ new account creation 
Return future fail for any failed validation

=cut

sub validate_user {
    my ($client, $new_account_params) = @_;

    # We need to make use that the user have default currency
    return create_error('SetExistingAccountCurrency') unless $client->default_account;

    # Country legal validation
    my $residence          = $client->residence;
    my $brand              = request()->brand;
    my $countries_instance = $brand->countries_instance;
    my $countries_list     = $countries_instance->countries_list;
    return create_error('InvalidAccountRegion') unless $countries_list->{$residence} && $countries_instance->is_signup_allowed($residence);

    # Check is account is mismacth with account_type
    return create_error('AccountTypesMismatch') if ($client->is_virtual() and $new_account_params->{account_type} ne 'demo');

    # Check if any required params for signup is not available
    my $requirements        = LandingCompany::Registry->by_name($new_account_params->{landing_company_short})->requirements;
    my $signup_requirements = $requirements->{signup};
    my @missing_fields      = grep { !$client->$_ } @$signup_requirements;

    return create_error(
        'MissingSignupDetails',
        {
            override_code => 'ASK_FIX_DETAILS',
            details       => {missing => [@missing_fields]}}) if ($new_account_params->{account_type} ne "demo" and @missing_fields);

    # Check if this country is one of the high risk country
    my $jurisdiction_ratings = BOM::Config::Compliance->new()->get_jurisdiction_risk_rating('mt5')->{$new_account_params->{landing_company_short}}
        // {};
    my $high_risk_countries = {map { $_ => 1 } @{$jurisdiction_ratings->{high} // []}};
    return create_error('DerivezNotAllowed') if $high_risk_countries->{$residence};

    my $compliance_requirements = $requirements->{compliance};

    if ($new_account_params->{group} !~ /^demo/) {
        return create_error('FinancialAssessmentRequired')
            unless _is_financial_assessment_complete(
            client                            => $client,
            group                             => $new_account_params->{group},
            financial_assessment_requirements => $compliance_requirements->{financial_assessment});

        # Following this regulation: Labuan Business Activity Tax
        # (Automatic Exchange of Financial Account Information) Regulation 2018,
        # we need to ask for tax details for selected countries if client wants
        # to open a financial account.
        return create_error('TINDetailsMandatory')
            if ($compliance_requirements->{tax_information}
            and $countries_instance->is_tax_detail_mandatory($residence)
            and not $client->status->crs_tin_information);
    }

    my %mt5_compliance_requirements = map { ($_ => 1) } $compliance_requirements->{mt5}->@*;
    if ($new_account_params->{account_type} ne 'demo' && $mt5_compliance_requirements{fully_authenticated}) {
        if ($client->fully_authenticated) {
            if ($mt5_compliance_requirements{expiration_check} && $client->documents->expired(1)) {
                $client->status->upsert('allow_document_upload', 'system', 'MT5_ACCOUNT_IS_CREATED');
                return create_error('ExpiredDocumentsMT5', {params => $client->loginid});
            }
        } else {
            $client->status->upsert('allow_document_upload', 'system', 'MT5_ACCOUNT_IS_CREATED');
            return create_error('AuthenticateAccount', {params => $client->loginid});
        }
    }

    if (    $client->tax_residence
        and $new_account_params->{account_type} ne 'demo'
        and $new_account_params->{group} =~ /real(?:\\p\d{2}_ts)?\d{2}\\financial\\(?:labuan|bvi)_stp_usd/)
    {
        # In case of having more than a tax residence, client residence will be replaced.
        my $selected_tax_residence = $client->tax_residence =~ /\,/g ? $client->residence : $client->tax_residence;
        my $tin_format             = $countries_instance->get_tin_format($selected_tax_residence);
        if (    $countries_instance->is_tax_detail_mandatory($selected_tax_residence)
            and $client->tax_identification_number
            and $tin_format)
        {
            # Some countries has multiple tax format and we should check all of them
            my $client_tin = $countries_instance->clean_tin_format($client->tax_identification_number);
            stats_inc('bom_rpc.v_3.new_mt5_account.called_with_wrong_TIN_format.count') unless (any { $client_tin =~ m/$_/ } @$tin_format);
        }
    }

    return;
}

=head2 generate_password

Generate a valid password based on the user's password for DerivEZ master and investor password

=cut

sub generate_password {
    my ($seed_str) = @_;
    # The password must contain at least two of three types of characters (lower case, upper case and digits)
    # We are not using random string for future usage consideration
    my $pwd = substr(sha384_hex($seed_str . 'E3xsTE6BQ=='), 0, 20);
    return $pwd . 'Hx_0';
}

=head2 derivez_group

my $group = BOM::TradingPlatform::Helper::HelperDerivEZ::derivez_group({
    residence             => $client->residence,
    landing_company_short => $client->landing_company->short,
    account_type          => $account_type,
    currency              => $client->currency,
});

Generate a valid DerivEZ group

=cut

sub derivez_group {
    my ($args) = shift;

    # Params required to build derivez group
    my ($landing_company_short, $account_type, $currency, $residence) = @{$args}{qw(landing_company_short account_type currency residence)};
    my $market_type      = 'all';
    my $sub_account_type = 'ez';
    my $server;

    # Affiliate landing company should map to seychelles
    my $lc = LandingCompany::Registry->by_name($landing_company_short);
    return 'real\p02_ts01\pandats\seychelles_ib_usd' if $lc->is_for_affiliates();

    if ($account_type eq 'demo') {
        # Server for demo account
        $server = get_trading_server($account_type, $residence, $market_type);
    } else {
        # Server for real account
        $server = get_trading_server($account_type, $residence, $market_type);

        # make the sub account type ib for affiliate accounts
        $sub_account_type = 'ib' if $lc->is_for_affiliates();

        # All financial account will be B-book (put in hr[high-risk] upon sign-up. Decisions to A-book will be done
        # on a case by case basis manually
        my $app_config = BOM::Config::Runtime->instance->app_config;
        $sub_account_type .= '-hr' if not $app_config->system->mt5->suspend->auto_Bbook_svg_financial;
    }

    # Restricted(limit) trading group
    $sub_account_type .= '-lim' if is_restricted_group($residence);

    # Combine all the params
    my @group_bits = ($account_type, $server, $market_type, join('_', ($landing_company_short, $sub_account_type, $currency)));

    # just making sure everything is lower case!
    return lc(join('\\', @group_bits));
}

=head2 is_account_demo

Return true if the group is demo

=cut

sub is_account_demo {
    my ($group) = @_;
    return $group =~ /demo/;
}

=head2 do_derivez_deposit

DerivEZ deposit implementation

=cut

sub do_derivez_deposit {
    my ($login, $amount, $comment, $txn_id) = @_;
    my $deposit_sub = \&BOM::MT5::User::Async::deposit;

    return $deposit_sub->({
            login   => $login,
            amount  => $amount,
            comment => $comment,
            txn_id  => $txn_id,
        }
    )->catch(
        sub {
            my $e = shift;
            BOM::RPC::v3::Utility::log_exception('mt5_deposit') if $txn_id;
            $error_handler->($e);
        })->get;
}

=head2 is_restricted_group

Check if the group is in mt5 restricted group list

=cut

sub is_restricted_group {
    my ($self, $residence) = @_;

    my $brand              = request()->brand;
    my $countries_instance = $brand->countries_instance;
    my $restricted_group   = $countries_instance->is_mt5_restricted_group($residence);

    return $restricted_group;
}

=head2 get_landing_company

Return the landing company based on the client residence and market type

=cut

sub get_landing_company {
    my ($client) = @_;

    return $client->landing_company->short if $client->landing_company->is_for_affiliates;

    my $countries = request()->brand->countries_instance;
    my $residence = $client->residence;

    return DERIVEZ_AVAILABLE_FOR if ($countries->gaming_company_for_country($residence)    // '') eq DERIVEZ_AVAILABLE_FOR;
    return DERIVEZ_AVAILABLE_FOR if ($countries->financial_company_for_country($residence) // '') eq DERIVEZ_AVAILABLE_FOR;

    return 'none';
}

=head2 is_derivez

Return true is it is for derivez

=cut

sub is_derivez {
    my ($param) = @_;

    my $result;
    if ($param->{login}) {
        $result = 1 if $param->{login} =~ /^EZ/;
        return $result;
    }

    if ($param->{group}) {
        $result = 1 if ($param->{group} =~ /_ez/ and $param->{group} =~ /all/);

        return $result;
    }

    return;
}

=head2 get_derivez_prefix

Return the prefix for derivez (EZR & EZD)

=cut

sub get_derivez_prefix {
    my ($param) = @_;

    if ($param->{login}) {
        return 'EZR' if $param->{login} =~ /^EZR\d+$/;
        return 'EZD' if $param->{login} =~ /^EZD\d+$/;

        die "Unexpected login id format $param->{login}";
    }

    if ($param->{group}) {
        return 'EZR' if $param->{group} =~ /^real/;
        return 'EZD' if $param->{group} =~ /^demo/;

        die "Unexpected group format $param->{group}";
    }

    die "Unexpected request params: " . join q{, } => keys %$param;
}

=head2 get_trading_server

Return the trading server for derivez

=cut

sub get_trading_server {
    my ($account_type, $residence, $market_type) = @_;

    my $server_routing_config = BOM::Config::derivez_server_routing_by_country();
    my $server_type           = $server_routing_config->{$account_type}->{$residence}->{$market_type}->{servers}->{standard};

    if (not defined $server_type) {
        $log->warnf("Routing config is missing for %s %s-%s", uc($residence), $account_type, $market_type) if $account_type ne 'demo';
        $server_type = ['p02_ts01'];
    }

    # We have already sorted the server based on their geolocation and offering in mt5_server_routing_by_country.yml
    # We are not using symmetrical_servers anymore and just fetch the server info
    my $servers = BOM::Config::MT5->new(
        group_type  => $account_type,
        server_type => $server_type
    )->get_server_webapi_info();

    # Flexible rollback plan for future new trade server
    my $mt5_app_config = BOM::Config::Runtime->instance->app_config->system->mt5;

    my @selected_servers;
    foreach my $server_key (keys %$servers) {
        my $group  = lc $servers->{$server_key}{geolocation}{group};
        my $weight = $mt5_app_config->load_balance->$account_type->$group->$server_key;
        unless (defined $weight) {
            $log->warnf("load balance weight is not defined for %s for account type %s", $server_key, $account_type);
            next;
        }
        push @selected_servers, [$server_key, $weight] if not $mt5_app_config->suspend->$account_type->$server_key->all;
    }

    # Return if this is the only trade server available
    return $selected_servers[0][0] if @selected_servers == 1;

    # If we have more than on trade servers, we distribute the load according to the weight specified
    # in the backoffice settings
    my @servers;
    foreach my $server (sort { $a->[1] <=> $b->[1] } @selected_servers) {
        push @servers, map { $server->[0] } (1 .. $server->[1]);
    }
    return $servers[int(_rand(@servers))] if @servers;
}

=head2 get_derivez_account_type_config

Return the group config for each derivez group (mt5_account_types.yml)

=cut

sub get_derivez_account_type_config {
    my ($group_name) = shift;

    my $group_accounttype = lc($group_name);

    return BOM::Config::mt5_account_types()->{$group_accounttype};
}

=head2 set_deriv_prefix_to_mt5

Setting up prefix from derivez to mt5 for BE uses

=cut

sub set_deriv_prefix_to_mt5 {
    my ($param) = @_;

    if ($param->{login}) {
        return 'MTR' if $param->{login} =~ /^EZR\d+$/;
        return 'MTD' if $param->{login} =~ /^EZD\d+$/;

        die "Unexpected login id format $param->{login}";
    }

    die "Unexpected request params: " . join q{, } => keys %$param;
}

=head2 derivez_accounts_lookup

Takes Client object and tries to fetch DerivEZ account information for each loginid
If loginid-related account does not exist on MT5 server, undef will be attached to the list

NOTE: We are using the same MT5 server for DerivEZ

=cut

sub derivez_accounts_lookup {
    my ($client, $account_type) = @_;
    my %allowed_error_codes = (
        ConnectionTimeout           => 1,
        MT5AccountInactive          => 1,
        NetworkError                => 1,
        NoConnection                => 1,
        NotFound                    => 1,
        ERR_NOSERVICE               => 1,
        'Service is not available.' => 1,
        'Timed out'                 => 1,
        'Connection closed'         => 1
    );

    my @futures;
    $account_type = $account_type ? $account_type : 'all';

    # Getting filtered account to only status as undef
    my @clients = $client->user->get_derivez_loginids(type_of_account => $account_type);
    for my $login (@clients) {
        my $f = _get_settings($client, $login)->then(
            sub {
                my ($setting) = @_;

                $setting = _filter_settings($setting,
                    qw/account_type balance country currency display_balance email group landing_company_short leverage login name market_type server server_info/
                ) if !$setting->{error};
                return $setting;
            }
        )->catch(
            sub {
                my ($resp) = @_;

                if ((
                        ref $resp eq 'HASH' && defined $resp->{error} && ref $resp->{error} eq 'HASH' && ($allowed_error_codes{$resp->{error}{code}}
                            || $allowed_error_codes{$resp->{error}{message_to_client}}))
                    || $allowed_error_codes{$resp})
                {
                    log_stats($login, $resp);
                    return Future->done(undef);
                } else {
                    $log->errorf("mt5_accounts_lookup Exception: %s", $resp);
                }

                return Future->fail($resp);
            });
        push @futures, $f;
    }

    # The reason for using wait_all instead of fmap here is:
    # to guaranty the MT5 circuit breaker test request will not be canceled when failing the other requests.
    # Note: using ->without_cancel to avoid cancel the future is not working
    # because our RPC is not totally async, where the worker will start processing another request after return the response
    # so the future in the background will never end
    return Future->wait_all(@futures)->then(
        sub {
            my @futures_result = @_;
            my $failed_future  = first { $_->is_failed } @futures_result;
            return Future->fail($failed_future->failure) if $failed_future;

            my @result = map { $_->result } @futures_result;
            return Future->done(@result);
        });
}

=head2 _get_settings

Takes a client object and a hash reference as inputs and returns the details of
the DerivEZ user, based on the DerivEZ login id passed.
It will return Future object.

=cut

sub _get_settings {
    my ($client, $login) = @_;

    return Future->fail(create_error('permission')) unless _check_logins($client, [$login]);

    if (BOM::MT5::User::Async::is_suspended('', {login => $login})) {
        my $account_type  = BOM::MT5::User::Async::get_account_type($login);
        my $server        = BOM::MT5::User::Async::get_trading_server_key({login => $login}, $account_type);
        my $server_config = BOM::Config::MT5->new(
            group_type  => $account_type,
            server_type => $server
        )->server_by_id();
        my $resp = {
            error => {
                code    => 'MT5AccountInaccessible',
                details => {
                    login        => $login,
                    account_type => $account_type,
                    server       => $server,
                    server_info  => {
                        id          => $server,
                        geolocation => $server_config->{$server}{geolocation},
                        environment => $server_config->{$server}{environment},
                    }
                },
                message_to_client => localize('MT5 is currently unavailable. Please try again later.'),
            }};
        return Future->done($resp);
    }

    return _get_user_with_group($login)->then(
        sub {
            my ($settings) = @_;

            return create_error('MT5AccountInactive') if !$settings->{active};

            $settings = _filter_settings($settings,
                qw/account_type address balance city company country currency display_balance email group landing_company_short leverage login market_type name phone phonePassword state zipCode server server_info/
            );

            return $settings;
        }
    )->catch(
        sub {
            my $err = shift;

            return create_error($err);
        });
}

=head2 _get_user_with_group

Fetching derivez users with their group.
It will return a future object

=cut

sub _get_user_with_group {
    my ($loginid) = shift;

    return BOM::MT5::User::Async::get_user($loginid)->then(
        sub {
            my ($settings) = @_;

            return create_error({
                    code    => 'DerivEZGetUserError',
                    message => $settings->{error}}) if (ref $settings eq 'HASH' and $settings->{error});
            if (my $country = $settings->{country}) {
                my $country_code = Locale::Country::Extra->new()->code_from_country($country);
                if ($country_code) {
                    $settings->{country} = $country_code;
                } else {
                    $log->warnf("Invalid country name $country for mt5 settings, can't extract code from Locale::Country::Extra");
                }
            }
            return $settings;
        }
    )->then(
        sub {
            my ($settings) = @_;

            return BOM::MT5::User::Async::get_group($settings->{group})->then(
                sub {
                    my ($group_details) = @_;

                    return create_error({
                            code    => 'GetGroupError',
                            message => $group_details->{error}}) if (ref $group_details eq 'HASH' and $group_details->{error});
                    $settings->{currency}        = $group_details->{currency};
                    $settings->{landing_company} = $group_details->{company};
                    $settings->{display_balance} = formatnumber('amount', $settings->{currency}, $settings->{balance});

                    _set_derivez_account_settings($settings) if ($settings->{group});

                    return $settings;
                });
        }
    )->catch(
        sub {
            my $err = shift;

            return create_error($err);
        });
}

=head2 _set_derivez_account_settings

populate derivez accounts with settings.

=cut

sub _set_derivez_account_settings {
    my ($account) = shift;

    my $group_name = lc($account->{group});
    my $config     = BOM::Config::mt5_account_types()->{$group_name};
    $account->{server}                = $config->{server};
    $account->{active}                = $config->{landing_company_short} ? 1 : 0;
    $account->{landing_company_short} = $config->{landing_company_short};
    $account->{market_type}           = $config->{market_type};
    $account->{account_type}          = $config->{account_type};

    if ($config->{server}) {
        my $server_config = BOM::Config::MT5->new(group => $group_name)->server_by_id();
        $account->{server_info} = {
            id          => $config->{server},
            geolocation => $server_config->{$config->{server}}{geolocation},
            environment => $server_config->{$config->{server}}{environment},
        };
    }
}

=head2 _filter_settings

Set the accounts required parameters

=cut

sub _filter_settings {
    my ($settings, @allowed_keys) = @_;
    my $filtered_settings = {};

    @{$filtered_settings}{@allowed_keys} = @{$settings}{@allowed_keys};
    $filtered_settings->{market_type} = 'synthetic' if $filtered_settings->{market_type} and $filtered_settings->{market_type} eq 'gaming';

    return $filtered_settings;
}

=head2 log_stats

Adds DD metrics related to 'derivez_accounts_lookup' allowed error codes

=cut

sub log_stats {

    my ($login, $resp) = @_;

    my $error_code    = $resp;
    my $error_message = $resp;

    if (ref $resp eq 'HASH') {
        $error_code    = $resp->{error}{code};
        $error_message = $resp->{error}{message_to_client};
    }

    # 'NotFound' error occurs if a user has at least one archived MT5 account. Since it is very common for users to have multiple archived
    # MT5 accounts and since this error is not critical, we will be excluding it from DD
    unless ($error_code eq 'NotFound') {
        stats_inc("mt5.accounts.lookup.error.code", {tags => ["login:$login", "error_code:$error_code", "error_messsage:$error_message"]});
    }
}

=head2 get_derivez_landing_company

Return the landing company for client

=cut

sub get_derivez_landing_company {
    my ($client) = @_;

    try {
        return $client->landing_company->short if $client->landing_company->is_for_affiliates;

        my $brand = request()->brand;

        my $countries_instance = $brand->countries_instance;

        return $countries_instance->all_company_for_country($client->residence);
    } catch {
        return {error => 'DerivezNotAllowed'};
    }
}

=head2 is_identical_group

Validate if we have duplicate account under same group for the same client

=cut

sub is_identical_group {
    my ($group, $existing_groups) = @_;

    my $group_config = get_derivez_account_type_config($group);

    foreach my $existing_group (map { get_derivez_account_type_config($_) } keys %$existing_groups) {
        return $existing_group if defined $existing_group and all { $group_config->{$_} eq $existing_group->{$_} } keys %$group_config;
    }

    return undef;
}

=head2 _is_financial_assessment_complete

Checks the financial assessment requirements of creating an account in an DerivEZ group.

=cut

sub _is_financial_assessment_complete {
    my %args = @_;

    my $client = $args{client};
    my $group  = $args{group};

    return 1 if $group =~ /^demo/;

    # this case doesn't follow the general rule (labuan are exclusively mt5 landing companies).
    if (my $financial_assessment_requirements = $args{financial_assessment_requirements}) {
        my $financial_assessment = BOM::User::FinancialAssessment::decode_fa($client->financial_assessment());

        my $is_FI =
            (first { $_ eq 'financial_information' } @{$args{financial_assessment_requirements}})
            ? BOM::User::FinancialAssessment::is_section_complete($financial_assessment, 'financial_information')
            : 1;

        # The `financial information` section is enough for `CR (svg)` clients. No need to check `trading_experience` section
        return 1 if $is_FI && $client->landing_company->short eq 'svg';

        my $is_TE =
            (first { $_ eq 'trading_experience' } @{$args{financial_assessment_requirements}})
            ? BOM::User::FinancialAssessment::is_section_complete($financial_assessment, 'trading_experience')
            : 1;

        ($is_FI and $is_TE) ? return 1 : return 0;
    }

    return $client->is_financial_assessment_complete();
}

=head2 derivez_validate_and_get_amount

Perform validation for account transfer and getting new updated amount

=cut

sub derivez_validate_and_get_amount {
    my ($authorized_client, $loginid, $mt5_loginid, $amount, $error_code, $currency_check) = @_;
    my $brand_name = request()->brand->name;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    return create_error('PaymentsSuspended', {override_code => $error_code})
        if ($app_config->system->suspend->payments);

    my $mt5_transfer_limits = BOM::Config::CurrencyConfig::mt5_transfer_limits($brand_name);

    # MT5 login or binary loginid not belongs to user
    my @loginids_list = ($mt5_loginid);
    push @loginids_list, $loginid if $loginid;

    return create_error('PermissionDenied', {message => 'Both accounts should belong to the authorized client.'})
        unless _check_logins($authorized_client, \@loginids_list);

    return _get_user_with_group($mt5_loginid)->then(
        sub {
            my ($setting) = @_;

            return create_error(
                'NoAccountDetails',
                {
                    override_code => $error_code,
                    params        => $mt5_loginid
                }) if (ref $setting eq 'HASH' && $setting->{error});

            my $action             = ($error_code =~ /Withdrawal/) ? 'withdrawal' : 'deposit';
            my $action_counterpart = ($error_code =~ /Withdrawal/) ? 'deposit'    : 'withdraw';

            my $mt5_group    = $setting->{group};
            my $mt5_lc       = _fetch_derivez_lc($setting);
            my $account_type = _is_account_demo($mt5_group) ? 'demo' : 'real';

            return create_error('InvalidMT5Group') unless $mt5_lc;

            my $requirements = $mt5_lc->requirements->{after_first_deposit}->{financial_assessment} // [];
            if (
                    $action eq 'withdrawal'
                and $authorized_client->has_mt5_deposits($mt5_loginid)
                and not _is_financial_assessment_complete(
                    client                            => $authorized_client,
                    group                             => $mt5_group,
                    financial_assessment_requirements => $requirements
                ))
            {
                return create_error('FinancialAssessmentRequired');
            }

            return create_error($setting->{status}->{withdrawal_locked}->{error}, {override_code => $error_code})
                if ($action eq 'withdrawal' and $setting->{status}->{withdrawal_locked});

            my $mt5_currency = $setting->{currency};
            return create_error('CurrencyConflict', {override_code => $error_code})
                if $currency_check && $currency_check ne $mt5_currency;

            # Check if it's called for virtual top up
            # If yes, then no need to validate client
            if ($account_type eq 'demo' and $action eq 'deposit' and not $loginid) {
                my $max_balance_before_topup = BOM::Config::payment_agent()->{minimum_topup_balance}->{DEFAULT};

                return create_error(
                    'DemoTopupBalance',
                    {
                        override_code => $error_code,
                        params        => [formatnumber('amount', $mt5_currency, $max_balance_before_topup), $mt5_currency]}
                ) if ($setting->{balance} > $max_balance_before_topup);

                return {top_up_virtual => 1};
            }

            return create_error('MissingID', {override_code => $error_code}) unless $loginid;

            return create_error('MissingAmount', {override_code => $error_code}) unless $amount;

            return create_error('WrongAmount', {override_code => $error_code}) if ($amount <= 0);

            my $client;
            try {
                $client = BOM::User::Client->get_client_instance($loginid, 'replica');

            } catch {
                BOM::RPC::v3::Utility::log_exception();
                return create_error(
                    'InvalidLoginid',
                    {
                        override_code => $error_code,
                        params        => $loginid
                    });
            }

            # Transfer between real and demo accounts is not permitted
            return create_error('AccountTypesMismatch') if $client->is_virtual xor ($account_type eq 'demo');
            # Transfer between virtual trading and virtual mt5 is not permitted
            return create_error('InvalidVirtualAccount') if $client->is_virtual and not $client->is_wallet;

            # Validate the binary client
            my ($err, $params) = _validate_client($client, $mt5_lc);
            return create_error(
                $err,
                {
                    override_code => $error_code,
                    params        => $params
                }) if $err;

            # Don't allow a virtual token/oauth to process a real account.
            return create_error('PermissionDenied',
                {message => localize('You cannot transfer between real accounts because the authorized client is virtual.')})
                if $authorized_client->is_virtual and not $client->is_virtual;

            my $client_currency = $client->account ? $client->account->currency_code() : undef;
            return create_error('TransferBetweenDifferentCurrencies')
                unless $client_currency eq $mt5_currency || $client->landing_company->mt5_transfer_with_different_currency_allowed;

            my $brand = Brands->new(name => request()->brand);

            return create_error(
                'WithdrawalLocked',
                {
                    override_code => $error_code,
                    params        => $brand->emails('support')})
                if ($action eq 'deposit'
                and ($client->status->no_withdrawal_or_trading or $client->status->withdrawal_locked));

            # Deposit should be locked if mt5 vanuatu/labuan account is disabled
            if (    $action eq 'deposit'
                and $mt5_group =~ /(?:labuan|vanuatu|bvi)/)
            {
                my $hex_rights   = BOM::Config::mt5_user_rights()->{'rights'};
                my %known_rights = map { $_ => hex $hex_rights->{$_} } keys %$hex_rights;
                my %rights       = map { $_ => $setting->{rights} & $known_rights{$_} ? 1 : 0 } keys %known_rights;
                if (not $rights{enabled} or $rights{trade_disabled}) {
                    return create_error('MT5DepositLocked');
                }
            }

            # Actual USD or EUR amount that will be deposited into the MT5 account.
            # We have a currency conversion fees when transferring between currencies.
            my $mt5_amount = undef;

            my $source_currency = $client_currency;

            my $mt5_currency_type    = LandingCompany::Registry::get_currency_type($mt5_currency);
            my $source_currency_type = LandingCompany::Registry::get_currency_type($source_currency);

            return create_error('TransferSuspended', {override_code => $error_code})
                if BOM::Config::Runtime->instance->app_config->system->suspend->transfer_between_accounts
                and (($source_currency_type // '') ne ($mt5_currency_type // ''));

            return create_error('TransfersBlocked', {message => localize("Transfers are not allowed for these accounts.")})
                if ($client->status->transfers_blocked && ($mt5_currency_type ne $source_currency_type));

            unless ((LandingCompany::Registry::get_currency_type($client_currency) ne 'crypto')
                || $mt5_currency eq $client_currency
                || offer_to_clients($client_currency))
            {
                stats_event(
                    'Exchange Rates Issue - No offering to clients',
                    'Please inform Quants and Backend Teams to check the exchange_rates for the currency.',
                    {
                        alert_type => 'warning',
                        tags       => ['currency:' . $client_currency . '_USD']});
                return create_error('NoExchangeRates');
            }

            my $fees                    = 0;
            my $fees_percent            = 0;
            my $fees_in_client_currency = 0;    #when a withdrawal is done record the fee in the local amount
            my ($min_fee, $fee_calculated_by_percent);

            if ($client_currency eq $mt5_currency) {
                $mt5_amount = $amount;
            } else {
                # we don't allow transfer between these two currencies
                my $disabled_for_transfer_currencies = BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies;

                return create_error(
                    'CurrencySuspended',
                    {
                        override_code => $error_code,
                        params        => [$source_currency, $mt5_currency]}
                ) if first { $_ eq $source_currency or $_ eq $mt5_currency } @$disabled_for_transfer_currencies;

                if ($action eq 'deposit') {

                    try {
                        ($mt5_amount, $fees, $fees_percent, $min_fee, $fee_calculated_by_percent) =
                            BOM::Platform::Client::CashierValidation::calculate_to_amount_with_fees(
                            amount        => $amount,
                            from_currency => $client_currency,
                            to_currency   => $mt5_currency,
                            country       => $client->residence,
                            );

                        $mt5_amount = financialrounding('amount', $mt5_currency, $mt5_amount);

                    } catch ($e) {
                        BOM::RPC::v3::Utility::log_exception();
                        # usually we get here when convert_currency() fails to find a rate within $rate_expiry, $mt5_amount is too low, or no transfer fee are defined (invalid currency pair).
                        $err        = $e;
                        $mt5_amount = undef;
                    }

                } elsif ($action eq 'withdrawal') {

                    try {

                        $source_currency = $mt5_currency;

                        ($mt5_amount, $fees, $fees_percent, $min_fee, $fee_calculated_by_percent) =
                            BOM::Platform::Client::CashierValidation::calculate_to_amount_with_fees(
                            amount        => $amount,
                            from_currency => $mt5_currency,
                            to_currency   => $client_currency,
                            country       => $client->residence,
                            );

                        $mt5_amount = financialrounding('amount', $client_currency, $mt5_amount);

                        # if last rate is expiered calculate_to_amount_with_fees would fail.
                        $fees_in_client_currency =
                            financialrounding('amount', $client_currency, convert_currency($fees, $mt5_currency, $client_currency));
                    } catch ($e) {
                        BOM::RPC::v3::Utility::log_exception();
                        # same as previous catch
                        $err = $e;
                    }
                }
            }

            if ($err) {
                return create_error(Date::Utility->new->is_a_weekend ? 'ClosedMarket' : 'NoExchangeRates', {override_code => $error_code})
                    if ($err =~ /No rate available to convert/);

                return create_error(
                    'NoTransferFee',
                    {
                        override_code => $error_code,
                        params        => [$client_currency, $mt5_currency]}) if ($err =~ /No transfer fee/);

                # Lower than min_unit in the receiving currency. The lower-bounds are not uptodate, otherwise we should not accept the amount in sending currency.
                # To update them, transfer_between_accounts_fees is called again with force_refresh on.
                return create_error(
                    'AmountNotAllowed',
                    {
                        override_code => $error_code,
                        params        => [$mt5_transfer_limits->{$source_currency}->{min}, $source_currency]}
                ) if ($err =~ /The amount .* is below the minimum allowed amount/);

                #default error:
                return create_error($error_code);
            }

            $err = BOM::RPC::v3::Cashier::validate_amount($amount, $source_currency);
            return create_error($error_code, {message => $err}) if $err;

            my $min = $mt5_transfer_limits->{$source_currency}->{min};

            return create_error(
                'InvalidMinAmount',
                {
                    override_code => $error_code,
                    params        => [formatnumber('amount', $source_currency, $min), $source_currency]}
            ) if $amount < financialrounding('amount', $source_currency, $min);

            my $max = $mt5_transfer_limits->{$source_currency}->{max};

            return create_error(
                'InvalidMaxAmount',
                {
                    override_code => $error_code,
                    params        => [formatnumber('amount', $source_currency, $max), $source_currency]}
            ) if $amount > financialrounding('amount', $source_currency, $max);

            unless ($client->is_virtual and _is_account_demo($mt5_group)) {
                my $rule_engine = BOM::Rules::Engine->new(client => $client);
                my $validation  = BOM::Platform::Client::CashierValidation::validate(
                    loginid           => $loginid,
                    action            => $action_counterpart,
                    is_internal       => 0,
                    underlying_action => ($action eq 'deposit' ? 'mt5_transfer' : 'mt5_withdraw'),
                    rule_engine       => $rule_engine
                );

                return create_error(
                    $error_code,
                    {
                        message       => $validation->{error}{message_to_client},
                        original_code => $validation->{error}{code}}) if exists $validation->{error};
            }

            return {
                derivez_amount          => $mt5_amount,
                fees                    => $fees,
                fees_currency           => $source_currency,
                fees_percent            => $fees_percent,
                fees_in_client_currency => $fees_in_client_currency,
                derivez_currency_code   => $mt5_currency,
                min_fee                 => $min_fee,
                calculated_fee          => $fee_calculated_by_percent,
                derivez_data            => $setting,
                account_type            => $account_type,
            };
        })->get;
}

=head2 record_derivez_transfer_to_mt5_transfer

Perform data insertion to mt5_transfer for DerivEZ transaction

=cut

sub record_derivez_transfer_to_mt5_transfer {
    my ($dbic, $payment_id, $derivez_amount, $derivez_login_id, $mt5_currency_code) = @_;

    $dbic->run(
        fixup => sub {
            my $sth = $_->prepare(
                'INSERT INTO payment.mt5_transfer
            (payment_id, mt5_amount, mt5_account_id, mt5_currency_code)
            VALUES (?,?,?,?)'
            );
            $sth->execute($payment_id, $derivez_amount, $derivez_login_id, $mt5_currency_code);
        });
    return 1;
}

=head2 send_transaction_email

Emit an event to send email for transaction

=cut

sub send_transaction_email {
    my %args = @_;
    my ($loginid, $mt5_id, $amount, $action, $error, $acc_type) = @args{qw(loginid mt5_id amount action error account_type)};
    my $brand = Brands->new(name => request()->brand);
    my $message =
        $action eq 'deposit'
        ? "Error happened when doing DerivEZ deposit after withdrawal from client account:"
        : "Error happened when doing deposit to client account after withdrawal from DerivEZ account:";

    return BOM::Platform::Email::send_email({
        from                  => $brand->emails('system'),
        to                    => $brand->emails('payments'),
        subject               => "DerivEZ $action error",
        message               => [$message, "Client login id: $loginid", "DerivEZ login: $mt5_id", "Amount: $amount", "error: $error"],
        use_email_template    => 1,
        email_content_is_html => 1,
        template_loginid      => ucfirst $acc_type . ' ' . $loginid =~ s/${\BOM::User->EZR_REGEX}//r,
    });
}

=head2 _check_logins

Validate client with valid login id given

=cut

sub _check_logins {
    my ($client, $logins) = @_;
    my $user = $client->user;
    foreach my $login (@{$logins}) {
        return unless (any { $login eq $_ } ($user->loginids));
    }
    return 1;
}

=head2 _fetch_derivez_lc

Return the landing company based on their group

=cut

sub _fetch_derivez_lc {
    my $settings = shift;

    my $group_params = parse_mt5_group($settings->{group});

    return undef unless $group_params->{landing_company_short};

    my $landing_company = LandingCompany::Registry->by_name($group_params->{landing_company_short});

    return undef unless $landing_company;

    return $landing_company;
}

=head2 _is_account_demo

Return true if the group is demo

=cut

sub _is_account_demo {
    my ($group) = @_;
    return $group =~ /demo/;
}

=head2 _validate_client

Validate the binary client

=cut

sub _validate_client {
    my ($client_obj, $mt5_lc) = @_;

    my $loginid = $client_obj->loginid;

    # if it's a legitimate virtual transfer, skip the rest of validations
    return undef if $client_obj->is_virtual;

    my $lc = $client_obj->landing_company->short;

    # We should not allow transfers between svg and maltainvest.
    return 'SwitchAccount' unless $lc eq DERIVEZ_AVAILABLE_FOR;

    # Deposits and withdrawals are blocked for non-authenticated MF clients
    return ('AuthenticateAccount', $loginid)
        if ($lc eq 'maltainvest' and not $client_obj->fully_authenticated);

    return ('AccountDisabled', $loginid) if ($client_obj->status->disabled);

    return ('CashierLocked', $loginid)
        if ($client_obj->status->cashier_locked);

    # check if binary client expired documents
    # documents->expired check internaly if landing company
    # needs expired documents check or not
    return ('ExpiredDocuments', request()->brand->emails('support')) if ($client_obj->documents->expired());

    # if mt5 financial accounts is used for deposit or withdraw
    # then check if client has valid documents or not
    # valid documents don't have additional landing companies check
    # that we have in documents->expired
    # TODO: Remove this once we have async mt5 in place
    return ('ExpiredDocuments', request()->brand->emails('support'))
        if ($mt5_lc->documents_expiration_check_required() and not $client_obj->documents->valid());

    my $client_currency = $client_obj->account ? $client_obj->account->currency_code() : undef;

    return ('SetExistingAccountCurrency', $loginid) unless $client_currency;

    my $daily_transfer_limit      = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->derivez;
    my $user_daily_transfer_count = $client_obj->user->daily_transfer_count('derivez');

    return ('MaximumTransfers', $daily_transfer_limit)
        unless $user_daily_transfer_count < $daily_transfer_limit;

    return undef;
}

=head2 do_derivez_withdrawal

DerivEZ withdrawal implementation

=cut

sub do_derivez_withdrawal {
    my ($login, $amount, $comment) = @_;
    my $withdrawal_sub = \&BOM::MT5::User::Async::withdrawal;

    return $withdrawal_sub->({
            login   => $login,
            amount  => $amount,
            comment => $comment,
        })->catch($error_handler)->get;
}

=head2 _rand

Returns a random number from 0 to 1.

=cut

sub _rand {
    my @servers = @_;
    return rand(@servers);
}

=head2 get_loginid_number

Returns only the loginid number instead of the Prefix + Number

=cut

sub get_loginid_number {
    my $loginid = shift;
    my ($loginid_number) = $loginid =~ /([0-9]+)/;

    return $loginid_number;
}

1;
