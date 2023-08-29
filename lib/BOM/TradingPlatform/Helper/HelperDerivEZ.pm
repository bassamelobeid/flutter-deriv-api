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
use Scalar::Util qw( looks_like_number );
use Math::BigFloat;

use base 'Exporter';
our @EXPORT_OK = qw(
    new_account_trading_rights
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
    get_transfer_fee_remark
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

=head2 validate_new_account_params

Validate the parameters for DerivEZ new account creation
Return future fail for any failed validation

=cut

sub validate_new_account_params {
    my (%args) = @_;

    # Check if any of the required params are missing
    my @required_params = ("account_type", "market_type", "platform", "company");
    my @missing_params  = grep { !defined $args{$_} } @required_params;
    die +{
        code   => 'DerivEZMissingParams',
        params => [@missing_params]} if @missing_params;

    # Check if the country support derivez
    die +{code => 'DerivEZNotAllowed'} if $args{company} eq 'none';

    # Account type should only be demo or real
    die +{code => 'InvalidAccountType'} if (not $args{account_type} or $args{account_type} !~ /^demo|real$/);

    # Market type for derivez should be "all"
    die +{code => 'InvalidMarketType'} if (not $args{market_type} or $args{market_type} !~ /^all$/);

    # Platform should be derivez
    die +{code => 'InvalidPlatform'} if $args{platform} ne 'derivez';
}

=head2 validate_user

Validate the user for DerivEZ new account creation
Return future fail for any failed validation

=cut

sub validate_user {
    my ($client, $new_account_params) = @_;

    # We need to make use that the user have default currency
    die +{code => 'SetExistingAccountCurrency'} unless $client->default_account;

    # Check if client country is allowed to singup
    my $residence          = $client->residence;
    my $brand              = request()->brand;
    my $countries_instance = $brand->countries_instance;
    my $countries_list     = $countries_instance->countries_list;
    die +{code => 'InvalidAccountRegion'} unless $countries_list->{$residence} && $countries_instance->is_signup_allowed($residence);

    # Check is account is mismacth with account_type
    die +{code => 'AccountTypesMismatch'} if ($client->is_virtual() and $new_account_params->{account_type} ne 'demo');

    # Check if any required params for signup is not available
    my $requirements        = LandingCompany::Registry->by_name($new_account_params->{landing_company_short})->requirements;
    my $signup_requirements = $requirements->{signup};
    my @missing_fields      = grep { !$client->$_ } @$signup_requirements;
    die +{
        code          => 'MissingSignupDetails',
        override_code => 'ASK_FIX_DETAILS',
        details       => {missing => [@missing_fields]}}
        if ($new_account_params->{account_type} ne "demo" and @missing_fields);

    # Check if this country is one of the high risk country
    my $jurisdiction_ratings = BOM::Config::Compliance->new()->get_jurisdiction_risk_rating('mt5')->{$new_account_params->{landing_company_short}}
        // {};
    my $restricted_risk_countries = {map { $_ => 1 } @{$jurisdiction_ratings->{restricted} // []}};
    die +{code => 'DerivezNotAllowed'} if $restricted_risk_countries->{$residence};

    my $compliance_requirements = $requirements->{compliance};
    if ($new_account_params->{group} !~ /^demo/) {
        die +{code => 'FinancialAssessmentRequired'}
            unless _is_financial_assessment_complete(
            client                            => $client,
            group                             => $new_account_params->{group},
            financial_assessment_requirements => $compliance_requirements->{financial_assessment});

        # Following this regulation: Labuan Business Activity Tax
        # (Automatic Exchange of Financial Account Information) Regulation 2018,
        # we need to ask for tax details for selected countries if client wants
        # to open a financial account.
        die +{code => 'TINDetailsMandatory'}
            if ($compliance_requirements->{tax_information}
            and $countries_instance->is_tax_detail_mandatory($residence)
            and not $client->status->crs_tin_information);
    }

    my %mt5_compliance_requirements = map { ($_ => 1) } $compliance_requirements->{mt5}->@*;
    if ($new_account_params->{account_type} ne 'demo' && $mt5_compliance_requirements{fully_authenticated}) {
        if ($client->fully_authenticated) {
            if ($mt5_compliance_requirements{expiration_check} && $client->documents->expired(1)) {
                $client->status->upsert('allow_document_upload', 'system', 'MT5_ACCOUNT_IS_CREATED');
                die +{code => 'ExpiredDocumentsMT5'};
            }
        } else {
            $client->status->upsert('allow_document_upload', 'system', 'MT5_ACCOUNT_IS_CREATED');
            die +{
                code   => 'AuthenticateAccount',
                params => $client->loginid
            };
        }
    }
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

            if (ref $e eq 'HASH' and $e->{code}) {
                stats_inc("derivez.deposit.error", {tags => ["login:$login", "message:" . $e->{error}]});

                die +{
                    code    => $e->{code},
                    message => $e->{error}};
            } else {
                stats_inc("derivez.deposit.error", {tags => ["login:$login", "message:$e"]});

                die +{
                    code    => 'DerivEZDepositError',
                    message => $e
                };
            }
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
    my @futures;

    # Define a hash of allowed error codes to ignore
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

    # Determine whether to get real or demo accounts, or both
    $account_type = $account_type ? $account_type : 'all';

    my @clients;

    if ($client->is_wallet) {
        my @all_linked_accounts = ($client->user->get_accounts_links(+{wallet_loginid => $client->loginid})->{$client->loginid} || [])->@*;

        @clients = map { $_->{platform} eq "derivez" ? $_->{loginid} : () } @all_linked_accounts;
    } elsif ($client->is_legacy) {
        # Getting filtered account to only status as undef and based on the specified account type
        @clients = $client->user->get_derivez_loginids(type_of_account => $account_type);
    }

    # Loop through all the accounts and create a future for each one to retrieve its settings
    for my $login (@clients) {
        my $f = _get_settings($client, $login)->then(
            sub {
                my ($setting) = @_;

                # Filter the settings to only include certain keys, if there are no errors
                $setting = _filter_settings($setting,
                    qw/account_type balance country currency display_balance email group landing_company_short leverage login name market_type server server_info/
                ) if !$setting->{error};

                return $setting;
            }
        )->catch(
            sub {
                my ($resp) = @_;

                # Ignore certain error codes and log the error for all others
                if (defined $resp->{code} and $allowed_error_codes{$resp->{code}}) {
                    return Future->done(undef);
                } elsif (defined $resp->{message} and $allowed_error_codes{$resp->{message}}) {
                    return Future->done(undef);
                } else {
                    $log->errorf("mt5_accounts_lookup Exception: %s", $resp->{message});
                }

                return Future->fail($resp);
            });
        push @futures, $f;
    }

    # Wait for all the futures to complete, handling any failures
    return Future->wait_all(@futures)->then(
        sub {
            my @futures_result = @_;

            # Returning failure if any is_failed
            my $failed_future = first { $_->is_failed } @futures_result;
            return Future->fail([$failed_future->failure]) if $failed_future;

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

    # Check if the loginid belongs to the client
    return Future->fail({code => 'permission'}) unless _check_logins($client, [$login]);

    # Check if the account is suspended
    if (BOM::MT5::User::Async::is_suspended('', {login => $login})) {

        # Get account details to include in response
        my $account_type = BOM::MT5::User::Async::get_account_type($login);
        my $server       = BOM::MT5::User::Async::get_trading_server_key({login => $login}, $account_type);
        my $server_info  = BOM::Config::MT5->new(
            group_type  => $account_type,
            server_type => $server
        )->server_by_id->{$server};

        # Build response
        my $resp = {
            code    => 'DerivEZAccountInaccessible',
            details => {
                login        => $login,
                account_type => $account_type,
                server       => $server,
                server_info  => {
                    id          => $server,
                    geolocation => $server_info->{geolocation},
                    environment => $server_info->{environment},
                },
            },
            message => localize('Deriv EZ is currently unavailable. Please try again later.'),
        };
        return Future->fail($resp);
    }

    # Retrieve user settings and group details
    return _get_user_with_group($login)->then(
        sub {
            my ($settings) = @_;

            # Check if the account is active
            return Future->fail({code => 'DerivEZAccountInactive'}) unless $settings->{active};

            # Filter the settings to only include necessary fields
            $settings = _filter_settings(
                $settings, qw/
                    account_type address balance city company country currency display_balance email
                    group landing_company_short leverage login market_type name phone phonePassword
                    state zipCode server server_info/
            );

            return $settings;
        }
    )->catch(
        sub {
            my ($err) = @_;

            # Return formated error
            return Future->fail($err);
        });
}

=head2 _get_user_with_group

Fetching derivez users with their group.
It will return a future object

=cut

sub _get_user_with_group {
    my ($loginid) = shift;

    # Get user settings for a given login ID
    return BOM::MT5::User::Async::get_user($loginid)->then(
        sub {
            my ($user_settings) = @_;

            # Convert country name to country code using Locale::Country::Extra
            if (my $country = $user_settings->{country}) {
                my $country_code = Locale::Country::Extra->new()->code_from_country($country);
                if ($country_code) {
                    $user_settings->{country} = $country_code;
                } else {
                    $log->warnf("Invalid country name $country for mt5 settings, can't extract code from Locale::Country::Extra");
                }
            }

            # Get group details for the user's group
            return BOM::MT5::User::Async::get_group($user_settings->{group})->then(
                sub {
                    my ($mt5_group_details) = @_;

                    # Set user settings with group details
                    $user_settings->{currency}        = $mt5_group_details->{currency};
                    $user_settings->{landing_company} = $mt5_group_details->{company};
                    $user_settings->{display_balance} = formatnumber('amount', $user_settings->{currency}, $user_settings->{balance});

                    # Set Derivez account settings if user belongs to a group
                    _set_derivez_account_settings($user_settings) if ($user_settings->{group});

                    return $user_settings;
                }
            )->catch(
                sub {
                    my ($err) = @_;

                    # Log error and increment stats counter
                    $log->errorf("_get_user_with_group failed for group %s: %s", $loginid, $err->{code});
                    stats_inc("derivez.get_group.error", {tags => ["error_message:$err->{code}"]});

                    # Return a failed Future with the error
                    # We need to return $err here since there is a difference between error structure from API and proxy container
                    # e.g $err->{message_to_client} only available on proxy container error

                    return Future->fail($err);
                });
        }
    )->catch(
        sub {
            my ($err) = @_;

            # Log error and increment stats counter
            $log->errorf("_get_user_with_group failed for user %s: %s", $loginid, $err->{code});
            stats_inc("derivez.get_user.error", {tags => ["error_code:$err->{code}"]});

            # Return a failed Future with the error
            # We need to return $err here since there is a difference between error structure from API and proxy container
            # e.g $err->{message_to_client} only available on proxy container error
            return Future->fail($err);
        });
}

=head2 _set_derivez_account_settings

populate derivez accounts with settings.

=cut

sub _set_derivez_account_settings {
    my ($account) = @_;

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
        return undef;
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
    my ($authorized_client, $loginid, $derivez_loginid, $amount, $error_code, $currency_check) = @_;
    my $brand_name = request()->brand->name;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    die +{code => 'PaymentsSuspended'} if ($app_config->system->suspend->payments);

    # Parameters check from FE
    die +{code => 'DerivEZMissingID'} unless $derivez_loginid;

    # MT5 login or binary loginid not belongs to user
    my @loginids_list = ($derivez_loginid);
    push @loginids_list, $loginid if $loginid;

    die +{
        code    => 'PermissionDenied',
        message => 'Both accounts should belong to the authorized client.'
        }
        unless _check_logins($authorized_client, \@loginids_list);

    return _get_user_with_group($derivez_loginid)->then(
        sub {
            # Extract user setting
            my ($user_setting) = @_;

            # Determine action based on error code
            my $action             = ($error_code =~ /Withdrawal/) ? 'withdrawal' : 'deposit';
            my $action_counterpart = ($action eq 'withdrawal')     ? 'deposit'    : 'withdraw';

            # Extract user details
            my $user_derivez_group           = $user_setting->{group};
            my $user_derivez_landing_company = _fetch_derivez_lc($user_setting);
            my $account_type                 = _is_account_demo($user_derivez_group) ? 'demo' : 'real';
            my $user_derivez_currency        = $user_setting->{currency};

            # Check if we have withdrawal_locked for the user
            die +{code => $error_code}
                if ($action eq 'withdrawal' and $user_setting->{status}->{withdrawal_locked});

            # Skip validation for virtual topup
            if ($account_type eq 'demo' and $action eq 'deposit' and not $loginid) {
                my $max_balance_before_topup = BOM::Config::payment_agent()->{minimum_topup_balance}->{DEFAULT};

                die +{
                    code   => 'DemoTopupBalance',
                    params => [formatnumber('amount', $user_derivez_currency, $max_balance_before_topup), $user_derivez_currency]}
                    if ($user_setting->{balance} > $max_balance_before_topup);

                return {top_up_virtual => 1};
            }

            die +{code => 'WrongAmount'} if ($amount <= 0);
            die +{code => 'MissingAmount'} unless $amount;

            # Check if the loginid is missing
            die +{code => 'MissingID'} unless $loginid;

            # Check landing company is valid
            die +{code => 'DerivEZInvalidLandingCompany'} unless $user_derivez_landing_company;

            # Check that derivez account currency matches with the tranfer currency parameters
            die +{code => 'CurrencyConflict'} if $currency_check && $currency_check ne $user_derivez_currency;

            # We should not allow transfer between cfd account (example: mt5 to derivez)
            # Will accept CR and MF only
            die +{
                code    => 'PermissionDenied',
                message => 'Transfer between cfd account is not permitted.'
            } if ($loginid =~ /^(?!CR|MF)/);

            # Populate variables
            my $requirements                     = $user_derivez_landing_company->requirements->{after_first_deposit}->{financial_assessment} // [];
            my $client                           = BOM::User::Client->get_client_instance($loginid, 'replica');
            my $brand                            = Brands->new(name => request()->brand);
            my $client_currency                  = $client->account ? $client->account->currency_code() : undef;
            my $user_derivez_currency_type       = LandingCompany::Registry::get_currency_type($user_derivez_currency);
            my $client_currency_type             = LandingCompany::Registry::get_currency_type($client_currency);
            my $disabled_for_transfer_currencies = BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies;
            my $derivez_transfer_limits          = BOM::Config::CurrencyConfig::derivez_transfer_limits($brand_name);
            my $source_currency                  = $action eq 'deposit' ? $client_currency : $user_derivez_currency;

            # Parameters
            my $derivez_transfer_amount = undef;
            my $fees                    = 0;
            my $fees_percent            = 0;
            my $fees_in_client_currency = 0;       #when a withdrawal is done record the fee in the local amount
            my ($min_fee, $fee_calculated_by_percent);

            # Check if financial assessment is required for withdrawals
            if (
                   $action eq 'withdrawal'
                && $authorized_client->has_mt5_deposits($derivez_loginid)
                && !_is_financial_assessment_complete(
                    client                            => $authorized_client,
                    group                             => $user_derivez_group,
                    financial_assessment_requirements => $requirements
                ))
            {
                die +{code => 'FinancialAssessmentRequired'};
            }

            # Transfer between real and demo accounts is not permitted
            die +{code => 'AccountTypesMismatch'} if $client->is_virtual xor ($account_type eq 'demo');

            # Transfer between virtual trading and virtual mt5 is not permitted
            die +{code => 'InvalidVirtualAccount'} if $client->is_virtual and not $client->is_wallet;

            # Check if the amount does not meet the min requirements
            my $min_transfer_limit = $derivez_transfer_limits->{$source_currency}->{min};
            die +{
                code   => 'InvalidMinAmount',
                params => [formatnumber('amount', $source_currency, $min_transfer_limit), $source_currency]}
                if $amount < financialrounding('amount', $source_currency, $min_transfer_limit);

            # Check if the amount exceed the max_transfer_limit requirements
            my $max_transfer_limit = $derivez_transfer_limits->{$source_currency}->{max};
            die +{
                code   => 'InvalidMaxAmount',
                params => [formatnumber('amount', $source_currency, $max_transfer_limit), $source_currency]}
                if $amount > financialrounding('amount', $source_currency, $max_transfer_limit);

            # Validate the binary client
            _validate_client($client, $user_derivez_landing_company);

            # Don't allow a virtual token/oauth to process a real account.
            die +{
                code    => 'PermissionDenied',
                message => localize('You cannot transfer between real accounts because the authorized client is virtual.')}
                if $authorized_client->is_virtual and not $client->is_virtual;

            # Do not allow transfer between different currencies
            die +{code => 'TransferBetweenDifferentCurrencies'}
                unless $client_currency eq $user_derivez_currency || $client->landing_company->mt5_transfer_with_different_currency_allowed;

            # Check for the client have withdrawal lock
            die +{
                code   => 'WithdrawalLocked',
                params => $brand->emails('support')}
                if ($action eq 'deposit'
                and ($client->status->no_withdrawal_or_trading or $client->status->withdrawal_locked));

            # Both currency type should be the same
            die +{code => 'TransferSuspended'}
                if BOM::Config::Runtime->instance->app_config->system->suspend->transfer_between_accounts
                and (($client_currency_type // '') ne ($user_derivez_currency_type // ''));

            # Check if the client transfer are blocked
            die +{
                code    => 'TransfersBlocked',
                message => localize("Transfers are not allowed for these accounts.")}
                if ($client->status->transfers_blocked && ($user_derivez_currency_type ne $client_currency_type));

            # Check if the exchange rates is offered
            unless (($client_currency_type ne 'crypto')
                || $user_derivez_currency eq $client_currency
                || offer_to_clients($client_currency))
            {
                stats_event(
                    'Exchange Rates Issue - No offering to clients',
                    'Please inform Quants and Backend Teams to check the exchange_rates for the currency.',
                    {
                        alert_type => 'warning',
                        tags       => ['currency:' . $client_currency . '_USD']});
                die +{code => 'NoExchangeRates'};
            }

            # We have a currency conversion fees when transferring between currencies.
            # Calculating exchange rate
            if ($client_currency eq $user_derivez_currency) {
                # We do not have any exchange rate for the same currency
                $derivez_transfer_amount = $amount;
            } else {
                # Check if the currency is one of the disabled tranfer currencies
                die +{
                    code   => 'CurrencySuspended',
                    params => [$client_currency, $user_derivez_currency]}
                    if first { $_ eq $client_currency or $_ eq $user_derivez_currency } @$disabled_for_transfer_currencies;

                if ($action eq 'deposit') {
                    try {
                        ($derivez_transfer_amount, $fees, $fees_percent, $min_fee, $fee_calculated_by_percent) =
                            BOM::Platform::Client::CashierValidation::calculate_to_amount_with_fees(
                            amount        => $amount,
                            from_currency => $client_currency,
                            to_currency   => $user_derivez_currency,
                            country       => $client->residence,
                            );

                        $derivez_transfer_amount = financialrounding('amount', $user_derivez_currency, $derivez_transfer_amount);

                    } catch ($e) {
                        stats_inc("derivez.deposit.validation.error");
                        # usually we get here when convert_currency() fails to find a rate within $rate_expiry, $derivez_transfer_amount is too low, or no transfer fee are defined (invalid currency pair).

                        die +{code => Date::Utility->new->is_a_weekend ? 'ClosedMarket' : 'NoExchangeRates'}
                            if ($e =~ /No rate available to convert/);

                        die +{
                            code   => 'NoTransferFee',
                            params => [$client_currency, $user_derivez_currency]} if ($e =~ /No transfer fee/);

                        # Lower than min_unit in the receiving currency. The lower-bounds are not up to date, otherwise we should not accept the amount in sending currency.
                        # To update them, transfer_between_accounts_fees is called again with force_refresh on.
                        die +{
                            code   => 'AmountNotAllowed',
                            params => [$min_transfer_limit, $source_currency]}
                            if ($e =~ /The amount .* is below the minimum allowed amount/);

                        # Default error:
                        die +{code => $error_code};
                    }

                } elsif ($action eq 'withdrawal') {
                    try {
                        ($derivez_transfer_amount, $fees, $fees_percent, $min_fee, $fee_calculated_by_percent) =
                            BOM::Platform::Client::CashierValidation::calculate_to_amount_with_fees(
                            amount        => $amount,
                            from_currency => $user_derivez_currency,
                            to_currency   => $client_currency,
                            country       => $client->residence,
                            );

                        $derivez_transfer_amount = financialrounding('amount', $client_currency, $derivez_transfer_amount);

                        # if last rate is expiered calculate_to_amount_with_fees would fail.
                        $fees_in_client_currency =
                            financialrounding('amount', $client_currency, convert_currency($fees, $user_derivez_currency, $client_currency));
                    } catch ($e) {
                        stats_inc("derivez.withdrawal.validation.error");

                        die +{code => Date::Utility->new->is_a_weekend ? 'ClosedMarket' : 'NoExchangeRates'}
                            if ($e =~ /No rate available to convert/);

                        die +{
                            code   => 'NoTransferFee',
                            params => [$client_currency, $user_derivez_currency]} if ($e =~ /No transfer fee/);

                        # Lower than min_unit in the receiving currency. The lower-bounds are not up to date, otherwise we should not accept the amount in sending currency.
                        # To update them, transfer_between_accounts_fees is called again with force_refresh on.
                        die +{
                            code   => 'AmountNotAllowed',
                            params => [$min_transfer_limit, $source_currency]}
                            if ($e =~ /The amount .* is below the minimum allowed amount/);

                        # Default error:
                        die +{code => $error_code};
                    }
                }
            }

            # Check if the amount is valid
            my $validate_amount_response = _validate_amount($amount, $source_currency);
            die +{
                code    => $error_code,
                message => $validate_amount_response
            } if $validate_amount_response;

            unless ($client->is_virtual and _is_account_demo($user_derivez_group)) {
                my $rule_engine = BOM::Rules::Engine->new(client => $client);
                my $validation  = BOM::Platform::Client::CashierValidation::validate(
                    loginid           => $loginid,
                    action            => $action_counterpart,
                    is_internal       => 0,
                    underlying_action => ($action eq 'deposit' ? 'mt5_transfer' : 'mt5_withdraw'),
                    rule_engine       => $rule_engine
                );

                die +{
                    code    => $error_code,
                    message => $validation->{error}{message_to_client}} if exists $validation->{error};
            }

            return {
                derivez_amount          => $derivez_transfer_amount,
                fees                    => $fees,
                fees_currency           => $source_currency,
                fees_percent            => $fees_percent,
                fees_in_client_currency => $fees_in_client_currency,
                derivez_currency_code   => $user_derivez_currency,
                min_fee                 => $min_fee,
                calculated_fee          => $fee_calculated_by_percent,
                derivez_data            => $user_setting,
                account_type            => $account_type,
            };
        }
    )->catch(
        sub {
            my $e = shift;

            if (ref $e eq 'HASH' and defined $e->{code}) {
                die +{
                    code    => $e->{code},
                    params  => $e->{params},
                    message => $e->{message}};
            } else {
                $log->errorf("derivez_validate_and_get_amount: %s", $e);
                die +{code => 'DerivEZNoAccountDetails'};
            }
        })->get;
}

=head2 record_derivez_transfer_to_mt5_transfer

Perform data insertion to mt5_transfer for DerivEZ transaction

=cut

sub record_derivez_transfer_to_mt5_transfer {
    my ($dbic, $payment_id, $derivez_amount, $derivez_login_id, $user_derivez_currency_code) = @_;

    $dbic->run(
        fixup => sub {
            my $sth = $_->prepare(
                'INSERT INTO payment.mt5_transfer
            (payment_id, mt5_amount, mt5_account_id, mt5_currency_code)
            VALUES (?,?,?,?)'
            );
            $sth->execute($payment_id, $derivez_amount, $derivez_login_id, $user_derivez_currency_code);
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
    die +{code => 'SwitchAccount'} unless $lc eq DERIVEZ_AVAILABLE_FOR;

    # Deposits and withdrawals are blocked for non-authenticated MF clients
    die +{
        code   => 'AuthenticateAccount',
        params => $loginid
        }
        if ($lc eq 'maltainvest' and not $client_obj->fully_authenticated);

    die +{
        code   => 'AccountDisabled',
        params => $loginid
    } if ($client_obj->status->disabled);

    die +{
        code   => 'CashierLocked',
        params => $loginid
        }
        if ($client_obj->status->cashier_locked);

    # check if binary client expired documents
    # documents->expired check internaly if landing company
    # needs expired documents check or not
    die +{
        code   => 'ExpiredDocuments',
        params => request()->brand->emails('support')} if ($client_obj->documents->expired());

    # if mt5 financial accounts is used for deposit or withdraw
    # then check if client has valid documents or not
    # valid documents don't have additional landing companies check
    # that we have in documents->expired
    # TODO: Remove this once we have async mt5 in place
    die +{
        code   => 'ExpiredDocuments',
        params => request()->brand->emails('support')}
        if ($mt5_lc->documents_expiration_check_required() and not $client_obj->documents->valid());

    my $client_currency = $client_obj->account ? $client_obj->account->currency_code() : undef;

    die +{
        code   => 'SetExistingAccountCurrency',
        params => request()->brand->emails('support')} unless $client_currency;

    my $daily_transfer_limit      = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->derivez;
    my $user_daily_transfer_count = $client_obj->user->daily_transfer_count('derivez');

    die +{
        code   => 'MaximumTransfers',
        params => $daily_transfer_limit
        }
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
        }
    )->catch(
        sub {
            my $e = shift;

            if (ref $e eq 'HASH' and $e->{code}) {
                stats_inc("derivez.withdrawal.error", {tags => ["login:$login", "message:" . $e->{error}]});

                die +{
                    code    => $e->{code},
                    message => $e->{error}};
            } else {
                stats_inc("derivez.withdrawal.error", {tags => ["login:$login", "message:$e"]});

                die +{
                    code    => 'DerivEZWithdrawalError',
                    message => $e
                };
            }
        });
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

=head2 _validate_amount

validate deposit/withdrawal ammount

=cut

sub _validate_amount {
    my ($amount, $currency) = @_;

    return localize('Invalid amount.') unless (looks_like_number($amount));

    my $num_of_decimals = Format::Util::Numbers::get_precision_config()->{amount}->{$currency};
    return localize('Invalid currency.') unless defined $num_of_decimals;
    my ($int, $precision) = Math::BigFloat->new($amount)->length();
    return localize('Invalid amount. Amount provided can not have more than [_1] decimal places.', $num_of_decimals)
        if ($precision > $num_of_decimals);

    return undef;
}

=head2 get_transfer_fee_remark

Returns a description for the fee applied to a transfer.
Takes the following list of arguments:

=over 4

=item fees: actual amount of fee to be applied.

=item fee_percent: the fee percentage used for the current transfer.

=item currency: currency of the sending account.

=item min_fee: the smallest amount meaningful in the sending currency.

=item fee_calculated_by_percent: the fee amount calculated directly by applying the fee percent alone.

=back

Returns a string in one of the following forms:

=over 4

=item '': when fees = 0

=item 'Includes transfer fee of USD 10 (0.5 %).': when fees >= min_fee

=item 'Includes minimim transfer fee of USD 0.01.': when fees < min_fee

=back

=cut

sub get_transfer_fee_remark {
    my (%args) = @_;

    return '' unless $args{fees};

    return "Includes transfer fee of "
        . formatnumber(
        amount => $args{fees_currency},
        $args{fee_calculated_by_percent})
        . " $args{fees_currency} ($args{fees_percent}%)."
        if $args{fee_calculated_by_percent} >= $args{min_fee};

    return "Includes the minimum transfer fee of $args{min_fee} $args{fees_currency}.";
}

1;
