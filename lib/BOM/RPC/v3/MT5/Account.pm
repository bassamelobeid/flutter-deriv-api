package BOM::RPC::v3::MT5::Account;

use strict;
use warnings;

no indirect;

use YAML::XS;
use Date::Utility;
use List::Util qw(any first all);
use Syntax::Keyword::Try;
use File::ShareDir;
use Locale::Country::Extra;
use WebService::MyAffiliates;
use Future::Utils qw(fmap1);
use Format::Util::Numbers qw/financialrounding formatnumber/;
use JSON::MaybeUTF8 qw(decode_json_utf8);
use DataDog::DogStatsd::Helper qw(stats_inc stats_event);
use Digest::SHA qw(sha384_hex);
use LandingCompany::Registry;
use ExchangeRates::CurrencyConverter qw/convert_currency offer_to_clients/;
use Log::Any qw($log);
use Locale::Country qw(country2code);

use BOM::RPC::Registry '-dsl';
use BOM::RPC::v3::MT5::Errors;
use BOM::RPC::v3::Utility qw(log_exception);
use BOM::RPC::v3::Cashier;
use BOM::RPC::v3::Accounts;
use BOM::Config;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Email qw(send_email);
use BOM::User;
use BOM::User::Utility qw(parse_mt5_group);
use BOM::User::Client;
use BOM::MT5::User::Async;
use BOM::Database::ClientDB;
use BOM::Config::Runtime;
use BOM::Platform::Email;
use BOM::Platform::Event::Emitter;
use BOM::Transaction;
use BOM::User::FinancialAssessment qw(is_section_complete decode_fa);

requires_auth();

use constant MT5_ACCOUNT_THROTTLE_KEY_PREFIX => 'MT5ACCOUNT::THROTTLE::';

use constant MT5_MALTAINVEST_MOCK_LEVERAGE => 33;
use constant MT5_MALTAINVEST_REAL_LEVERAGE => 30;

use constant MT5_SVG_FINANCIAL_MOCK_LEVERAGE => 1;
use constant MT5_SVG_FINANCIAL_REAL_LEVERAGE => 1000;

use constant MT5_VIRTUAL_MONEY_DEPOSIT_COMMENT => 'MT5 Virtual Money deposit';

my $error_registry = BOM::RPC::v3::MT5::Errors->new();
my $error_handler  = sub {
    my $err = shift;

    if (ref $err eq 'HASH' and $err->{code}) {
        create_error_future($err->{code}, {message => $err->{error}});
    } else {
        return Future->fail($err);
    }
};

sub create_error_future {
    my ($error_code, $details, @extra) = @_;
    if (ref $details eq 'HASH' and ref $details->{message} eq 'HASH') {
        return Future->fail({error => $details->{message}});
    }
    return Future->fail($error_registry->format_error($error_code, $details, @extra));

}

=head2 mt5_login_list

    $mt5_logins = mt5_login_list({ client => $client })

Takes a client object and returns all possible MT5 login IDs
associated with that client. Otherwise, returns an error message indicating
that MT5 is suspended.

Takes the following (named) parameters:

=over 4

=item * C<params> hashref that contains a BOM::User::Client object under the key C<client>.

=back

Returns any of the following:

=over 4

=item * A hashref that contains the following keys:

=over 4

=item * C<code> stating C<MT5APISuspendedError>.

=item * C<message_to_client> that says C<MT5 API calls are suspended.>.

=back

=item * An arrayref that contains hashrefs. Each hashref contains:

=over 4

=item * C<login> - The MT5 loginID of the client.

=item * C<group> - (optional) The group the loginID belongs to.

=back

=back

=cut

async_rpc "mt5_login_list",
    category => 'mt5',
    sub {
    my $params = shift;

    my $client = $params->{client};

    return get_mt5_logins($client)->then(
        sub {
            my (@logins) = @_;
            return Future->done(\@logins);
        });
    };

=head2 get_mt5_logins

$mt5_logins = get_mt5_logins($client)

Takes Client object and fetch all its available and active MT5 accounts

Takes the following parameter:

=over 4

=item * C<params> hashref that contains a C<BOM::User::Client>

=back

Returns a Future holding list of MT5 account information or a failed future with error information

=cut

sub get_mt5_logins {
    my ($client) = @_;

    return mt5_accounts_lookup($client)->then(
        sub {
            my (@logins) = @_;
            my @valid_logins = grep { defined $_ and $_ } @logins;

            return Future->done(@valid_logins);
        });
}

=head2 mt5_accounts_lookup

$mt5_logins = mt5_accounts_lookup($client)

Takes Client object and tries to fetch MT5 account information for each loginid
If loginid-related account does not exist on MT5, undef will be attached to the list

Takes the following parameter:

=over 4

=item * C<params> hashref that contains a C<BOM::User::Client>

=item * C<args> - additional parameters to retrieve all accounts

=back

Returns a Future holding list of MT5 account information (or undef) or a failed future with error information

=cut

sub mt5_accounts_lookup {
    my ($client) = @_;

    my $f = fmap1 {
        my $login = shift;
        return mt5_get_settings({
                client => $client,
                args   => {login => $login}}
        )->then(
            sub {
                my ($setting) = @_;

                $setting = _filter_settings($setting,
                    qw/account_type balance country currency display_balance email group landing_company_short leverage login name market_type sub_account_type server/
                );
                return Future->done($setting);
            }
        )->catch(
            sub {
                my ($resp) = @_;
                if (   defined $resp->{error}
                    && ref $resp->{error} eq 'HASH'
                    && ($resp->{error}{code} eq 'NotFound' || $resp->{error}{code} eq 'MT5AccountInactive'))
                {
                    return Future->done(undef);
                }

                return Future->fail($resp);
            });
    }
    foreach        => [grep { !BOM::MT5::User::Async::is_suspended('', {login => $_}) } $client->user->get_mt5_loginids],
        concurrent => 4;
    # purely to keep perlcritic+perltidy happy :(

    return $f;
}

# limit number of requests to once per minute
sub _throttle {
    my $loginid = shift;
    my $key     = MT5_ACCOUNT_THROTTLE_KEY_PREFIX . $loginid;

    return 1 if BOM::Config::Redis::redis_replicated_read()->get($key);

    BOM::Config::Redis::redis_replicated_write()->set($key, 1, 'EX', 60);

    return 0;
}

# removes the database entry that limit requests to 1/minute
# returns 1 if entry was present, 0 otherwise
sub reset_throttler {
    my $loginid = shift;
    my $key     = MT5_ACCOUNT_THROTTLE_KEY_PREFIX . $loginid;

    return BOM::Config::Redis::redis_replicated_write()->del($key);
}

=head2 _mt5_group

Group naming convention for mt5 is as follow:

${account_type}${server_type}\${market_type}\${landing_company_short}_${sub_account_type}_${currency}

where:

account_type: demo|real
server_type: 01|02|...
market_type: financial|synthetic
landing_company_short: svg|maltainvest|samoa|...
sub_account_type: std[standard]|sf[swap-free]|hf[high-risk]
currency: usd|gbp|...

How does this map to the input?

account_type:     demo|gaming|financial
mt5_account_type  financial|financial_stp
mt5_account_category: conventional|swap_free|empty for financial_stp

=cut

sub _mt5_group {
    my $args = shift;

    my ($landing_company_short, $account_type, $mt5_account_type, $currency, $account_category, $country, $user_input_trade_server) =
        @{$args}{qw(landing_company_short account_type mt5_account_type currency sub_account_type country server)};

    # account creation for samoa if not allowed until the launch of deriv-crypto
    return '' if $landing_company_short eq 'samoa';

    my ($server_type, $market_type, $sub_account_type);
    if ($account_type eq 'demo') {
        # $server_type is defaulted to 01 for demo since we do not have demo trade server cluster
        $server_type = '01';
        # if $mt5_account_type is undefined, it maps to $market_type=synthetic, else $market_type=financial
        $market_type      = $mt5_account_type ? 'financial' : 'synthetic';
        $sub_account_type = _get_sub_account_type($mt5_account_type, $account_category);
        # we need to override the currency here because virtual account default currency is all in USD
        $currency = LandingCompany::Registry::get($landing_company_short)->get_default_currency($country);
    } else {
        # real group mapping
        my $orig_account_type = $account_type;
        $account_type     = 'real';
        $market_type      = $orig_account_type eq 'gaming' ? 'synthetic' : 'financial';
        $server_type      = _get_server_type($account_type, $country, $market_type);
        $sub_account_type = _get_sub_account_type($mt5_account_type, $account_category);
        # All svg financial account will be B-book (put in hr[high-risk] upon sign-up. Decisions to A-book will be done
        # on a case by case basis manually
        my $app_config = BOM::Config::Runtime->instance->app_config;
        # only consider b-booking financial for svg and samoa
        my $apply_auto_b_book = (
            $market_type eq 'financial' and ($landing_company_short eq 'svg'
                or $landing_company_short eq 'samoa')
                and not $app_config->system->mt5->suspend->auto_Bbook_svg_financial
        );
        $sub_account_type .= '-hr' if $market_type eq 'financial' and $sub_account_type ne 'stp' and not $apply_auto_b_book;
    }

    # TODO (JB): Refactor this.
    # - user is only allowed to create account on real02, real03 and real04 if he/she is not from Ireland trade server country list ($server_type = '01')
    # - user from Ireland trade server country list will be allowed to create account on real01, real02, real03 and real04
    return '' if (defined $user_input_trade_server and $server_type ne '01' and $user_input_trade_server eq 'real01');

    my $mt5_trade_server = defined $user_input_trade_server ? $user_input_trade_server : ${account_type} . ${server_type};

    return ${mt5_trade_server} . '\\' . $market_type . '\\' . join('_', map { lc $_ } ($landing_company_short, $sub_account_type, $currency));
}

=head2 _get_server_type

Returns key of trading server that corresponds to the account type(demo/real) and country

=over 4

=item * account type

=item * country

=back

Takes the following parameters:

=over 4

=item * C<$account_type> - string representing type of the MT5 sevrer (demo/real)

=item * C<$country> - Alpha-2 code of the country 

=back 

Returns the trading server key 

=cut

# Register new users in this server by default
my $DEFAULT_TRADING_SERVER_KEY = '01';

sub _get_server_type {
    my ($account_type, $country, $market_type) = @_;

    my $server_routing_config = BOM::Config::mt5_server_routing();

    # just in case we pass in the name of the country instead of the country code.
    if (length $country != 2) {
        $country = country2code($country);
    }

    # if it is not defined, set $server_type to $DEFAULT_TRADING_SERVER_KEY
    my $server_type = $server_routing_config->{$account_type}->{$country}->{$market_type} // $DEFAULT_TRADING_SERVER_KEY;

    # Flexible rollback plan for future new trade server
    my $mt5_app_config    = BOM::Config::Runtime->instance->app_config->system->mt5;
    my $new_server_config = decode_json_utf8($mt5_app_config->new_trade_server);
    my $method            = $account_type . $server_type;

    if (my $new = $new_server_config->{$method}) {
        if ($mt5_app_config->suspend->$method->all) {
            $server_type = $DEFAULT_TRADING_SERVER_KEY;
        } elsif ($new->{all}) {    # according to $server_routing_config
            $server_type = $new->{all};
        } elsif ($new->{$country} and $new->{$country}{$market_type}) {    # just this country & market tyep
            $server_type = $new->{$country}{$market_type};
        } else {
            $server_type = $DEFAULT_TRADING_SERVER_KEY;
        }
    }

    return $server_type;
}

=head2 _get_sub_account_type

Returns sub account type that corresponds to the mt5 account type and account category.

Takes the following parameters:

=over 4

=item * C<$mt5_account_type> - string representing the mt5 account type (financial|financial_stp)

=item * C<$account_category> - string representing mt5 account category (conventional|swap_free)

=back

=cut

sub _get_sub_account_type {
    my ($mt5_account_type, $account_category) = @_;

    # $sub_account_type depends on $mt5_account_type and $account_category. It is a little confusing, but can't do much about it.
    my $sub_account_type = 'std';
    if (defined $mt5_account_type and $mt5_account_type eq 'financial_stp') {
        $sub_account_type = 'stp';
    } elsif (defined $account_category and $account_category eq 'swap_free') {
        $sub_account_type = 'sf';
    }

    return $sub_account_type;
}

async_rpc "mt5_new_account",
    category => 'mt5',
    sub {
    my $params = shift;

    my $error_code = 'MT5CreateUserError';

    my ($client, $args) = @{$params}{qw/client args/};

    # extract request parameters
    my $account_type            = delete $args->{account_type};
    my $mt5_account_type        = delete $args->{mt5_account_type} // '';
    my $mt5_account_category    = delete $args->{mt5_account_category} // 'conventional';
    my $user_input_trade_server = delete $args->{server};

    # input validation
    return create_error_future('SetExistingAccountCurrency') unless $client->default_account;

    my $invalid_account_type_error = create_error_future('InvalidAccountType');
    return $invalid_account_type_error if (not $account_type or $account_type !~ /^demo|gaming|financial$/);

    # - demo account cannot select trade server
    # - financial account cannot select trade server
    return create_error_future('InvalidServerInput') if $account_type ne 'gaming' and defined $user_input_trade_server;

    $mt5_account_type     = '' if $account_type eq 'gaming';
    $mt5_account_category = '' if $mt5_account_type eq 'financial_stp' or $mt5_account_category !~ /^swap_free|conventional$/;

    my $passwd_validation_err = BOM::RPC::v3::Utility::validate_mt5_password({
        email           => $client->email,
        main_password   => $args->{mainPassword} // '',
        invest_password => $args->{investPassword} // '',
    });
    return create_error_future($passwd_validation_err) if $passwd_validation_err;

    $args->{investPassword} = _generate_password($args->{mainPassword}) unless $args->{investPassword};

    return create_error_future('InvalidSubAccountType')
        if ($mt5_account_type and $mt5_account_type !~ /^financial|financial_stp/)
        or ($account_type eq 'financial' and $mt5_account_type eq '');

    # legal validation
    my $residence = $client->residence;

    my $brand              = request()->brand;
    my $countries_instance = $brand->countries_instance;
    my $countries_list     = $countries_instance->countries_list;

    return create_error_future('permission') unless $countries_list->{$residence};

    my $user = $client->user;

    # demo accounts type determined if this parameter exists or not
    my $company_type = $mt5_account_type eq '' ? 'gaming' : 'financial';
    # swap_free is considered as sub account type in config files
    my $sub_account_type = $mt5_account_category eq 'swap_free' ? $mt5_account_category : $mt5_account_type;
    my $company_name     = $countries_instance->mt_company_for_country(
        country          => $residence,
        account_type     => $company_type,
        sub_account_type => $sub_account_type
    );

    # MT5 is not allowed in client country
    return create_error_future($mt5_account_category eq 'swap_free' ? 'MT5SwapFreeNotAllowed' : 'MT5NotAllowed', {params => $company_type})
        if $company_name eq 'none';

    my $binary_company_name = $countries_list->{$residence}->{"${company_type}_company"};

    my $source_client = $client;

    my $company_matching_required = $account_type ne 'demo' || $countries_list->{$residence}->{config}->{match_demo_mt5_to_existing_accounts};

    # Binary.com front-end will pass whichever client is currently selected
    # in the top-right corner, so check if this user has a qualifying account and switch if they do.
    if ($company_matching_required and $client->landing_company->short ne $binary_company_name) {
        my @clients = $user->clients_for_landing_company($binary_company_name);
        # remove disabled/duplicate accounts to make sure that atleast one Real account is active
        @clients = grep { !$_->status->disabled && !$_->status->duplicate_account } @clients;
        $client  = (@clients > 0) ? $clients[0] : undef;
    }

    # No matching binary account was found; let's see what was the reason.
    unless ($client) {
        # First we check if a real mt5 accounts was being created with no real binary account existing
        return create_error_future('RealAccountMissing')
            if ($account_type ne 'demo' and scalar($user->clients) == 1 and $source_client->is_virtual());

        # Then there might be a binary account with matching company type missing
        return create_error_future('FinancialAccountMissing') if $company_type eq 'financial';
        return create_error_future('GamingAccountMissing');
    }

    return create_error_future('permission') if ($client->is_virtual() and $account_type ne 'demo');

    my $requirements        = LandingCompany::Registry->new->get($company_name)->requirements;
    my $signup_requirements = $requirements->{signup};
    my @missing_fields      = grep { !$client->$_ } @$signup_requirements;

    return create_error_future(
        'MissingSignupDetails',
        {
            override_code => 'ASK_FIX_DETAILS',
            details       => {missing => [@missing_fields]}}) if ($account_type ne "demo" and @missing_fields);

    # Selecting a currency for a mt5 account can be pretty tricky. On mt5, each group has a denominated currency.
    # The allowed currency for each landing company does not match the group we have on mt5. For example:
    # - MF clients can choose between USD, EUR & GBP as binary account currency.
    # - On mt5, we have only maltainvest EUR and maltainvest GBP groups.
    #
    # So, the logic of mt5 account currency is based on the following rules:
    # 1. If client's selected currency is one of the available_mt5_currency_group then, it will be used as the mt5 account currency
    # 2. Else, the landing company's default currency will be used.
    #
    # A practical example:
    # - MF (residence: germany) client with selected account currency of USD. The mt5 account currency will be EUR.
    # - MF (residence: germany) client with selected account currency of GBP. The mt5 account currency will be GBP.
    my $default_currency       = $client->landing_company->get_default_currency($residence);
    my $available_mt5_currency = $client->landing_company->available_mt5_currency_group();
    my $selected_currency      = (any { $client->currency eq $_ } @$available_mt5_currency) ? $client->currency : $default_currency;
    my $mt5_account_currency   = $args->{currency} // $selected_currency;

    return create_error_future('permission') if $mt5_account_currency ne $selected_currency;

    my $group = _mt5_group({
        country               => $residence,
        landing_company_short => $company_name,
        account_type          => $account_type,
        mt5_account_type      => $mt5_account_type,
        currency              => $mt5_account_currency,
        sub_account_type      => $mt5_account_category,
        server                => $user_input_trade_server,
    });

    # something is wrong if we're not able to get group config
    return create_error_future('permission') if $group eq '' || !get_mt5_account_type_config($group);

    my $config = request()->brand->countries_instance->countries_list->{$client->residence};
    if ($config->{mt5_age_verification}
        and not $client->status->age_verification)
    {
        return ($client->is_virtual() and $user->clients == 1)
            ? create_error_future('RealAccountMissing')
            : create_error_future('NoAgeVerification');
    }

    if ($group !~ /^demo/) {
        my $compliance_requirements = $requirements->{compliance};
        return create_error_future('FinancialAssessmentMandatory')
            unless _is_financial_assessment_complete(
            client                            => $client,
            group                             => $group,
            financial_assessment_requirements => $compliance_requirements->{financial_assessment});

        # Following this regulation: Labuan Business Activity Tax
        # (Automatic Exchange of Financial Account Information) Regulation 2018,
        # we need to ask for tax details for selected countries if client wants
        # to open a financial account.
        return create_error_future('TINDetailsMandatory')
            if ($compliance_requirements->{tax_information}
            and $countries_instance->is_tax_detail_mandatory($residence)
            and not $client->status->crs_tin_information);
    }
    if (    $account_type ne 'demo'
        and $company_name eq 'labuan'
        and not $client->fully_authenticated)
    {
        $client->status->setnx('allow_document_upload', 'system', 'MT5_ACCOUNT_IS_CREATED');
        return create_error_future('AuthenticateAccount', {params => $client->loginid});
    }

    #TODO (JB): clean up old group name after we have migrated all accounts to new group
    # - real\labuan_financial_stp
    if (    $client->tax_residence
        and $account_type ne 'demo'
        and ($group eq 'real\labuan_financial_stp' or $group =~ /real\d{2}\\financial\\labuan_stp_usd/))
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
    # Check if client is throttled before sending MT5 request
    if (_throttle($client->loginid)) {
        return create_error_future('Throttle', {override_code => $error_code});
    }

    if ($args->{dry_run}) {
        return Future->done({
                account_type    => $account_type,
                balance         => 0,
                currency        => 'USD',
                display_balance => '0.00',
                ($mt5_account_type) ? (mt5_account_type => $mt5_account_type) : ()});
    }

    return get_mt5_logins($client)->then(
        sub {
            my (@logins) = @_;

            my %existing_groups = map { $_->{group} => $_->{login} } grep { $_->{group} } @logins;

            # can't create account on the same group
            # TODO (JB): We can remove this after we've moved all the accounts to the new group name.
            # Basically, for now real\svg is identical to real01\synthetic\svg_std_usd or real02\synthetic\svg_std_usd
            if (my $identical = _is_identical_group($group, \%existing_groups)) {
                return create_error_future(
                    'MT5Duplicate',
                    {
                        override_code => $error_code,
                        params        => [$account_type, $existing_groups{$identical}]});
            }

            # A client can only have either one of
            # real\vanuatu_financial or real\svg_financial or real\svg_financial_Bbook
            # ignore samoa for now, since their groups follow different pattern.
            if ($mt5_account_type eq 'financial' && $company_name ne 'samoa') {
                if (my $similar = _is_similar_group($company_name, \%existing_groups)) {
                    return create_error_future(
                        'MT5Duplicate',
                        {
                            override_code => $error_code,
                            params        => [$account_type, $existing_groups{$similar}]});
                }
            }

            # TODO(leonerd): This has to nest because of the `Future->done` in the
            #   foreach loop above. A better use of errors-as-failures might avoid
            #   this.
            return BOM::MT5::User::Async::get_group($group)->then(
                sub {
                    my ($group_details) = @_;
                    if (ref $group_details eq 'HASH' and my $error = $group_details->{error}) {
                        return create_error_future($error_code, {message => $error});
                    }
                    # some MT5 groups should have leverage as 30
                    # but MT5 only support 33
                    if ($group_details->{leverage} == MT5_MALTAINVEST_MOCK_LEVERAGE) {
                        $group_details->{leverage} = MT5_MALTAINVEST_REAL_LEVERAGE;
                    } elsif ($group_details->{leverage} == MT5_SVG_FINANCIAL_MOCK_LEVERAGE) {
                        # MT5 bug it should be solved by MetaQuote
                        $group_details->{leverage} = MT5_SVG_FINANCIAL_REAL_LEVERAGE;
                    }

                    my $client_info = $client->get_mt5_details();
                    $client_info->{name} = $args->{name} if $client->is_virtual;
                    @{$args}{keys %$client_info} = values %$client_info;
                    $args->{group}    = $group;
                    $args->{leverage} = $group_details->{leverage};
                    $args->{currency} = $group_details->{currency};

                    # else get one associated with affiliate token
                    #only affiliate who is also an introducing Broker has mt5_account in myaffiliates
                    if ($client->myaffiliates_token and $account_type ne 'demo') {
                        my $agent_login = _get_mt5_account_from_affiliate_token({
                            token        => $client->myaffiliates_token,
                            user         => $user,
                            account_type => $account_type eq 'demo' ? 'demo' : 'real',
                            country      => $residence,
                            market       => $group =~ /financial/ ? 'financial' : 'synthetic',
                        });
                        $args->{agent} = $agent_login if $agent_login;
                        $log->warnf("Unable to link %s MT5 account with myaffiliates token %s", $client->loginid, $client->myaffiliates_token)
                            unless $agent_login;
                    }

                    return BOM::MT5::User::Async::create_user($args);
                }
            )->then(
                sub {
                    my ($status) = @_;

                    if ($status->{error}) {
                        return create_error_future('permission') if $status->{error} =~ /Not enough permissions/;
                        return create_error_future($error_code, {message => $status->{error}});
                    }
                    my $mt5_login = $status->{login};
                    $user->add_loginid($mt5_login);

                    BOM::Platform::Event::Emitter::emit(
                        'new_mt5_signup',
                        {
                            loginid          => $client->loginid,
                            account_type     => $account_type,
                            sub_account_type => $mt5_account_type,
                            mt5_group        => $group,
                            mt5_login_id     => $mt5_login,
                            cs_email         => $brand->emails('support'),
                            language         => $params->{language}});

                    # Compliance team must be notified if a client under Deriv (Europe) Limited
                    #   opens an MT5 account while having limitations on their account.
                    if ($client->landing_company->short eq 'malta' && $account_type ne 'demo') {
                        my $self_exclusion = BOM::RPC::v3::Accounts::get_self_exclusion({client => $client});
                        if (keys %$self_exclusion) {
                            warn 'Compliance email regarding Deriv (Europe) Limited user with MT5 account(s) failed to send.'
                                unless BOM::RPC::v3::Accounts::send_self_exclusion_notification($client, 'malta_with_mt5', $self_exclusion);
                        }
                    }

                    my $balance = 0;
                    # TODO(leonerd): This other somewhat-ugly structure implements
                    #   conditional execution of a Future-returning block. It's a bit
                    #   messy. See also
                    #     https://rt.cpan.org/Ticket/Display.html?id=124040
                    return (
                        do {
                            if ($account_type eq 'demo') {
                                # funds in Virtual money
                                $balance = 10000;
                                do_mt5_deposit($mt5_login, $balance, MT5_VIRTUAL_MONEY_DEPOSIT_COMMENT)->on_done(
                                    sub {
                                        # TODO(leonerd): It'd be nice to turn these into failed
                                        #   Futures from BOM::MT5::User::Async also.
                                        my ($status) = @_;

                                        # deposit failed
                                        if ($status->{error}) {
                                            warn "MT5: deposit failed for virtual account with error " . $status->{error};
                                            $balance = 0;
                                        }
                                    });
                            } else {
                                Future->done;
                            }
                        }
                    )->then(
                        sub {
                            # Get currency from MT5 group
                            return BOM::MT5::User::Async::get_group($group);
                        }
                    )->then(
                        sub {
                            my ($group_details) = @_;
                            return create_error_future('MT5CreateUserError', {message => $group_details->{error}})
                                if ref $group_details eq 'HASH' and $group_details->{error};

                            return Future->done({
                                    login           => $mt5_login,
                                    balance         => $balance,
                                    display_balance => formatnumber('amount', $args->{currency}, $balance),
                                    currency        => $args->{currency},
                                    account_type    => $account_type,
                                    agent           => $args->{agent},
                                    ($mt5_account_category) ? (mt5_account_category => $mt5_account_category) : (),
                                    ($mt5_account_type)     ? (mt5_account_type     => $mt5_account_type)     : ()});
                        });
                });
        })->catch($error_handler);
    };

=head2 _is_financial_assessment_complete

Checks the financial assessment requirements of creating an account in an MT5 group.

Takes named argument with the following as key parameters:

=over 4

=item * $client: an instance of C<BOM::User::Client> representing a binary client onject.

=item * $group: the target MT5 group.

=item * $financial_assessment_requirements for particular landing company.

=back

Returns 1 of the financial assemssments meet the requirements; otherwise returns 0.

=cut

sub _is_financial_assessment_complete {
    my %args = @_;

    my $client = $args{client};
    my $group  = $args{group};

    return 1 if $group =~ /^demo/;

    # this case doesn't follow the general rule (labuan are exclusively mt5 landing companies).
    if (my $financial_assessment_requirements = $args{financial_assessment_requirements}) {
        my $financial_assessment = decode_fa($client->financial_assessment());

        my $is_FI =
            (first { $_ eq 'financial_information' } @{$args{financial_assessment_requirements}})
            ? is_section_complete($financial_assessment, 'financial_information')
            : 1;

        # The `financial information` section is enough for `CR (svg)` clients. No need to check `trading_experience` section
        return 1 if $is_FI && $client->landing_company->short eq 'svg';

        my $is_TE =
            (first { $_ eq 'trading_experience' } @{$args{financial_assessment_requirements}})
            ? is_section_complete($financial_assessment, 'trading_experience')
            : 1;

        ($is_FI and $is_TE) ? return 1 : return 0;
    }

    return $client->is_financial_assessment_complete();
}

sub _check_logins {
    my ($client, $logins) = @_;
    my $user = $client->user;
    foreach my $login (@{$logins}) {
        return unless (any { $login eq $_ } ($user->loginids));
    }
    return 1;
}

=head2 mt5_get_settings

    $user_mt5_settings = mt5_get_settings({
        client  => $client,
        args    => $args
    })

Takes a client object and a hash reference as inputs and returns the details of
the MT5 user, based on the MT5 login id passed.

Takes the following (named) parameters as inputs:

=over 4

=item * C<params> hashref that contains:

=over 4

=item * A BOM::User::Client object under the key C<client>.

=item * A hash reference under the key C<args> that contains the MT5 login id
under C<login> key.

=back

=back

Returns any of the following:

=over 4

=item * A hashref error message that contains the following keys, based on the given error:

=over 4

=item * MT5 suspended

=over 4

=item * C<code> stating C<MT5APISuspendedError>.

=back

=item * Permission denied

=over 4

=item * C<code> stating C<PermissionDenied>.

=back

=item * Retrieval Error

=over 4

=item * C<code> stating C<MT5GetUserError>.

=back

=back

=item * A hashref that contains the details of the user's MT5 account.

=back

=cut

async_rpc "mt5_get_settings",
    category => 'mt5',
    sub {
    my $params = shift;

    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    return create_error_future('permission') unless _check_logins($client, [$login]);
    return _get_user_with_group($login)->then(
        sub {
            my ($settings) = @_;

            return create_error_future('MT5AccountInactive') if !$settings->{active};

            $settings = _filter_settings($settings,
                qw/account_type address balance city company country currency display_balance email group landing_company_short leverage login market_type name phone phonePassword state sub_account_type zipCode server/
            );

            return Future->done($settings);
        })->catch($error_handler);
    };

sub _filter_settings {
    my ($settings, @allowed_keys) = @_;
    my $filtered_settings = {};
    @{$filtered_settings}{@allowed_keys} = @{$settings}{@allowed_keys};
    return $filtered_settings;
}

sub get_mt5_account_type_config {
    my ($group_name) = shift;

    my $group_accounttype = lc($group_name);

    return BOM::Config::mt5_account_types()->{$group_accounttype};
}

sub set_mt5_account_settings {
    my ($settings) = shift;

    my $group_name = lc($settings->{group});
    my $config     = get_mt5_account_type_config($group_name);
    $settings->{server}                = $config->{server};
    $settings->{active}                = $config->{landing_company_short} ? 1 : 0;
    $settings->{landing_company_short} = $config->{landing_company_short};
    $settings->{market_type}           = $config->{market_type};
    $settings->{account_type}          = $config->{account_type};
    $settings->{sub_account_type}      = $config->{sub_account_type};

}

sub _get_user_with_group {
    my ($loginid) = shift;

    return BOM::MT5::User::Async::get_user($loginid)->then(
        sub {
            my ($settings) = @_;
            return create_error_future('MT5GetUserError', {message => $settings->{error}}) if (ref $settings eq 'HASH' and $settings->{error});
            if (my $country = $settings->{country}) {
                my $country_code = Locale::Country::Extra->new()->code_from_country($country);
                if ($country_code) {
                    $settings->{country} = $country_code;
                } else {
                    warn "Invalid country name $country for mt5 settings, can't extract code from Locale::Country::Extra";
                }
            }
            return Future->done($settings);
        }
    )->then(
        sub {
            my ($settings) = @_;
            return BOM::MT5::User::Async::get_group($settings->{group})->then(
                sub {
                    my ($group_details) = @_;
                    return create_error_future('MT5GetGroupError', {message => $group_details->{error}})
                        if (ref $group_details eq 'HASH' and $group_details->{error});
                    $settings->{currency}        = $group_details->{currency};
                    $settings->{landing_company} = $group_details->{company};
                    $settings->{display_balance} = formatnumber('amount', $settings->{currency}, $settings->{balance});

                    set_mt5_account_settings($settings) if ($settings->{group});

                    return Future->done($settings);
                });
        })->catch($error_handler);
}

=head2 mt5_password_check

    $mt5_pass_check = mt5_password_check({
        client  => $client,
        args    => $args
    })

Takes a client object and a hash reference as inputs and returns 1 upon
successful validation of the user's password.

Takes the following (named) parameters as inputs:

=over 4

=item * C<params> hashref that contains:

=over 4

=item * A BOM::User::Client object under the key C<client>.

=item * A hash reference under the key C<args> that contains the MT5 login id
under C<login> key.

=back

=back

Returns any of the following:

=over 4

=item * A hashref error message that contains the following keys, based on the given error:

=over 4

=item * MT5 suspended

=over 4

=item * C<code> stating C<MT5APISuspendedError>.

=back

=item * Permission denied

=over 4

=item * C<code> stating C<PermissionDenied>.

=back

=item * Retrieval Error

=over 4

=item * C<code> stating C<MT5PasswordCheckError>.

=back

=back

=item * Returns 1, indicating successful validation.

=back

=cut

async_rpc "mt5_password_check",
    category => 'mt5',
    sub {
    my $params = shift;

    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    # MT5 login not belongs to user
    return create_error_future('permission') unless _check_logins($client, [$login]);

    return BOM::MT5::User::Async::password_check({
            login    => $args->{login},
            password => $args->{password},
            type     => $args->{password_type} // 'main'
        }
    )->then(
        sub {
            my ($status) = @_;

            if ($status->{error}) {
                return create_error_future('MT5PasswordCheckError', {message => $status->{error}});
            }
            return Future->done(1);
        })->catch($error_handler);
    };

=head2 mt5_password_change

    $mt5_pass_change = mt5_password_change({
        client  => $client,
        args    => $args
    })

Takes a client object and a hash reference as inputs and returns 1 upon
successful change of the user's MT5 account password.

Takes the following (named) parameters as inputs:

=over 4

=item * C<params> hashref that contains:

=over 4

=item * A BOM::User::Client object under the key C<client>.

=item * A hash reference under the key C<args> that contains:

=over 4

=item * C<login> that contains the MT5 login id.

=item * C<old_password> that contains the user's current password.

=item * C<new_password> that contains the user's new password.

=back

=back

=back

Returns any of the following:

=over 4

=item * A hashref error message that contains the following keys, based on the given error:

=over 4

=item * MT5 suspended

=over 4

=item * C<code> stating C<MT5APISuspendedError>.

=back

=item * Permission denied

=over 4

=item * C<code> stating C<PermissionDenied>.

=back

=item * Retrieval Error

=over 4

=item * C<code> stating C<MT5PasswordChangeError>.

=back

=back

=item * Returns 1, indicating successful change.

=back

=cut

async_rpc "mt5_password_change",
    category => 'mt5',
    sub {
    my $params = shift;

    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    return create_error_future('MT5PasswordChangeError') if $args->{old_password} and ($args->{new_password} eq $args->{old_password});
    # MT5 login not belongs to user
    return create_error_future('permission') unless _check_logins($client, [$login]);

    if (_throttle($client->loginid)) {
        return create_error_future('Throttle', {override_code => 'MT5PasswordChangeError'});
    }

    my $passwd_validation_err = BOM::RPC::v3::Utility::validate_mt5_password({
            email         => $client->email,
            main_password => $args->{new_password}});
    return create_error_future($passwd_validation_err) if $passwd_validation_err;

    return BOM::MT5::User::Async::password_check({
            login    => $login,
            password => $args->{old_password},
            type     => $args->{password_type} // 'main',
        }
    )->then(
        sub {
            my ($status) = @_;

            if ($status->{error}) {
                return create_error_future($status->{code}, {override_code => 'MT5PasswordChangeError'});
            }

            return BOM::MT5::User::Async::password_change({
                    login        => $login,
                    new_password => $args->{new_password},
                    type         => $args->{password_type} // 'main',
                })->then_done(1);
        }
    )->then(
        sub {
            BOM::Platform::Event::Emitter::emit(
                'mt5_password_changed',
                {
                    loginid     => $client->loginid,
                    mt5_loginid => $login
                });
            return Future->done(1);
        },
        sub {
            my $err = shift;
            return create_error_future($err->{code});
        });
    };

=head2 mt5_password_reset

    $mt5_pass_reset = mt5_password_reset({
        client  => $client,
        args    => $args
    })

Takes a client object and a hash reference as inputs and returns 1 upon
successful reset the user's MT5 account password.

Takes the following (named) parameters as inputs:

=over 3

=item * C<params> hashref that contains:

=over 3

=item * A BOM::User::Client object under the key C<client>.

=item * A hash reference under the key C<args> that contains:

=over 3

=item * C<login> that contains the MT5 login id.

=item * C<new_password> that contains the user's new password.

=back

=back

=back

Returns any of the following:

=over 3

=item * A hashref error message that contains the following keys, based on the given error:

=over 3

=item * MT5 suspended

=over 4

=item * C<code> stating C<MT5APISuspendedError>.

=back

=item * Permission denied

=over 3

=item * C<code> stating C<PermissionDenied>.

=back

=item * Retrieval Error

=over 3

=item * C<code> stating C<MT5PasswordChangeError>.

=back

=back

=item * Returns 1, indicating successful reset.

=back

=cut

async_rpc "mt5_password_reset",
    category => 'mt5',
    sub {
    my $params = shift;

    my $client = $params->{client};
    my $args   = $params->{args};
    my $login  = $args->{login};

    my $email = $client->user->email;

    my $verification = BOM::RPC::v3::Utility::is_verification_token_valid($args->{verification_code}, $email, 'mt5_password_reset');

    if ($verification->{error}) {
        return Future->fail($verification);
    }

    # MT5 login not belongs to user
    return create_error_future('permission')
        unless _check_logins($client, [$login]);

    my $passwd_validation_err = BOM::RPC::v3::Utility::validate_mt5_password({
            email         => $email,
            main_password => $args->{new_password}});
    return create_error_future($passwd_validation_err) if $passwd_validation_err;

    return BOM::MT5::User::Async::password_change({
            login        => $login,
            new_password => $args->{new_password},
            type         => $args->{password_type} // 'main',
        }
    )->then(
        sub {
            my ($status) = @_;

            if ($status->{error}) {
                return create_error_future($status->{code}, {override_code => 'MT5PasswordChangeError'});
            }

            send_email({
                    from    => Brands->new(name => request()->brand)->emails('support'),
                    to      => $email,
                    subject => localize('Your MT5 password has been reset.'),
                    message => [
                        localize(
                            'The password for your MT5 account [_1] has been reset. If this request was not performed by you, please immediately contact Customer Support.',
                            $email
                        )
                    ],
                    use_email_template    => 1,
                    email_content_is_html => 1,
                    template_loginid      => ucfirst BOM::MT5::User::Async::get_account_type($login) . ' ' . $login =~ s/${\BOM::User->MT5_REGEX}//r,
                });

            return Future->done(1);

        })->catch($error_handler);
    };

sub _send_email {
    my %args = @_;
    my ($loginid, $mt5_id, $amount, $action, $error, $acc_type) = @args{qw(loginid mt5_id amount action error account_type)};
    my $brand = Brands->new(name => request()->brand);
    my $message =
        $action eq 'deposit'
        ? "Error happened when doing MT5 deposit after withdrawal from client account:"
        : "Error happened when doing deposit to client account after withdrawal from MT5 account:";

    return BOM::Platform::Email::send_email({
        from                  => $brand->emails('system'),
        to                    => $brand->emails('payments'),
        subject               => "MT5 $action error",
        message               => [$message, "Client login id: $loginid", "MT5 login: $mt5_id", "Amount: $amount", "error: $error"],
        use_email_template    => 1,
        email_content_is_html => 1,
        template_loginid      => ucfirst $acc_type . ' ' . $loginid =~ s/${\BOM::User->MT5_REGEX}//r,
    });
}

async_rpc "mt5_deposit",
    category => 'mt5',
    sub {
    my $params = shift;

    my ($client, $args, $source) = @{$params}{qw/client args source/};
    my ($fm_loginid, $to_mt5, $amount, $return_mt5_details) =
        @{$args}{qw/from_binary to_mt5 amount return_mt5_details/};

    my $error_code = 'MT5DepositError';
    my $app_config = BOM::Config::Runtime->instance->app_config;

    # no need to throttle this call only limited numbers of transfers are allowed

    return create_error_future('Experimental')
        if BOM::RPC::v3::Utility::verify_experimental_email_whitelisted($client, $client->currency);

    return _mt5_validate_and_get_amount($client, $fm_loginid, $to_mt5, $amount, $error_code)->then(
        sub {
            my ($response) = @_;
            return Future->done($response) if (ref $response eq 'HASH' and $response->{error});

            my $account_type;
            if ($response->{top_up_virtual}) {

                my $amount_to_topup = 10000;

                return do_mt5_deposit($to_mt5, $amount_to_topup, MT5_VIRTUAL_MONEY_DEPOSIT_COMMENT)->then(
                    sub {
                        my ($status) = @_;

                        if ($status->{error}) {
                            return create_error_future($status->{code});
                        }

                        reset_throttler($to_mt5);

                        return Future->done({status => 1});
                    });
            } else {
                # this status is intended to block withdrawals from binary to MT5
                return create_error_future('WithdrawalLocked', {override_code => $error_code}) if $client->status->mt5_withdrawal_locked;

                $account_type = 'real';
            }

            my $fm_client = BOM::User::Client->new({loginid => $fm_loginid});

            # From the point of view of our system, we're withdrawing
            # money to deposit into MT5
            try {
                $fm_client->validate_payment(
                    currency          => $fm_client->default_account->currency_code(),
                    amount            => -1 * $amount,
                    internal_transfer => 1,
                );
            } catch {
                my $withdraw_error = $@;
                return create_error_future(
                    $error_code,
                    {
                        message => BOM::RPC::v3::Cashier::__client_withdrawal_notes({
                                client => $fm_client,
                                amount => $amount,
                                error  => $withdraw_error
                            })});
            }

            my $fees              = $response->{fees};
            my $fees_currency     = $response->{fees_currency};
            my $fees_percent      = $response->{fees_percent};
            my $mt5_currency_code = $response->{mt5_currency_code};
            my ($txn, $comment);
            try {
                my $fee_calculated_by_percent = $response->{calculated_fee};
                my $min_fee                   = $response->{min_fee};
                my $mt5_login_id              = $to_mt5 =~ s/${\BOM::User->MT5_REGEX}//r;
                $comment = "Transfer from $fm_loginid to MT5 account $account_type $mt5_login_id";
                my $additional_comment = BOM::RPC::v3::Cashier::get_transfer_fee_remark(
                    fees                      => $fees,
                    fee_percent               => $fees_percent,
                    currency                  => $fees_currency,
                    minimum_fee               => $min_fee,
                    fee_calculated_by_percent => $fee_calculated_by_percent
                );
                $comment = "$comment $additional_comment" if $additional_comment;

                ($txn) = $fm_client->payment_mt5_transfer(
                    amount   => -$amount,
                    currency => $fm_client->currency,
                    staff    => $fm_loginid,
                    remark   => $comment,
                    fees     => $fees,
                    source   => $source,
                );

                _record_mt5_transfer($fm_client->db->dbic, $txn->payment_id, -$response->{mt5_amount}, $to_mt5, $response->{mt5_currency_code});

                BOM::Platform::Event::Emitter::emit(
                    'transfer_between_accounts',
                    {
                        loginid    => $fm_client->loginid,
                        properties => {
                            from_account       => $fm_loginid,
                            is_from_account_pa => 0 + !!($fm_client->is_pa_and_authenticated),
                            to_account         => $to_mt5,
                            is_to_account_pa   => 0 + !!($fm_client->is_pa_and_authenticated),
                            from_currency      => $fm_client->currency,
                            to_currency        => $mt5_currency_code,
                            from_amount        => $amount,
                            to_amount          => $response->{mt5_amount},
                            source             => $source,
                            fees               => $fees,
                            gateway_code       => 'mt5_transfer',
                            id                 => $txn->{id},
                            time               => $txn->{transaction_time}}});
            } catch {
                my $error = BOM::Transaction->format_error(err => $@);
                return create_error_future($error_code, {message => $error->{-message_to_client}});
            }

            # TODO (JB): clean up old group name after we have migrated all accounts to new group
            # - real\vanuatu_financial
            _store_transaction_redis({
                    loginid       => $fm_loginid,
                    mt5_id        => $to_mt5,
                    action        => 'deposit',
                    amount_in_USD => convert_currency($amount, $fm_client->currency, 'USD'),
                })
                if ($response->{mt5_data}->{group} eq 'real\vanuatu_financial'
                or $response->{mt5_data}->{group} =~ /real\d{2}\\financial\\vanuatu_std-hr_usd/);

            my $txn_id = $txn->transaction_id;
            # 31 character limit for MT5 comments
            my $mt5_comment = "${fm_loginid}_${to_mt5}#$txn_id";

            # deposit to MT5 a/c
            return do_mt5_deposit($to_mt5, $response->{mt5_amount}, $mt5_comment, $txn_id)->then(
                sub {
                    my ($status) = @_;

                    if ($status->{error}) {
                        log_exception('mt5_deposit');
                        _send_email(
                            loginid      => $fm_loginid,
                            mt5_id       => $to_mt5,
                            amount       => $amount,
                            action       => 'deposit',
                            error        => $status->{error},
                            account_type => $account_type
                        );
                        return create_error_future($status->{code});
                    }

                    return Future->done({
                            status                => 1,
                            binary_transaction_id => $txn_id,
                            $return_mt5_details ? (mt5_data => $response->{mt5_data}) : ()});
                });
        });
    };

async_rpc "mt5_withdrawal",
    category => 'mt5',
    sub {
    my $params = shift;

    my ($client, $args, $source) = @{$params}{qw/client args source/};
    my ($fm_mt5, $to_loginid, $amount, $currency_check) =
        @{$args}{qw/from_mt5 to_binary amount currency_check/};

    my $error_code = 'MT5WithdrawalError';
    my $app_config = BOM::Config::Runtime->instance->app_config;

    # no need to throttle this call only limited numbers of transfers are allowed

    return create_error_future('Experimental')
        if BOM::RPC::v3::Utility::verify_experimental_email_whitelisted($client, $client->currency);

    my $to_client = BOM::User::Client->new({loginid => $to_loginid});

    return _mt5_validate_and_get_amount($client, $to_loginid, $fm_mt5, $amount, $error_code, $currency_check)->then(
        sub {
            my ($response) = @_;
            return Future->done($response) if (ref $response eq 'HASH' and $response->{error});
            my $account_type = 'real';    # withdrawal is not allowed for demo accounts

            my $fees                      = $response->{fees};
            my $fees_currency             = $response->{fees_currency};
            my $fees_in_client_currency   = $response->{fees_in_client_currency};
            my $mt5_amount                = $response->{mt5_amount};
            my $fees_percent              = $response->{fees_percent};
            my $mt5_currency_code         = $response->{mt5_currency_code};
            my $fee_calculated_by_percent = $response->{calculated_fee};
            my $min_fee                   = $response->{min_fee};

            my $mt5_login_id       = $fm_mt5 =~ s/${\BOM::User->MT5_REGEX}//r;
            my $comment            = "Transfer from MT5 account $account_type $mt5_login_id to $to_loginid.";
            my $additional_comment = BOM::RPC::v3::Cashier::get_transfer_fee_remark(
                fees                      => $fees,
                fee_percent               => $fees_percent,
                currency                  => $fees_currency,
                minimum_fee               => $min_fee,
                fee_calculated_by_percent => $fee_calculated_by_percent
            );

            $comment = "$comment $additional_comment" if $additional_comment;

            # 31 character limit for MT5 comments
            my $mt5_comment = "${fm_mt5}_${to_loginid}";

            my $mt5_group = $response->{mt5_data}->{group};
            #MT5 expect this value to be negative.
            # withdraw from MT5 a/c
            return do_mt5_withdrawal($fm_mt5, (($amount > 0) ? $amount * -1 : $amount), $mt5_comment)->then(
                sub {
                    my ($status) = @_;
                    return create_error_future($status->{code}) if (ref $status eq 'HASH' and $status->{error});

                    # TODO(leonerd): This try block returns a Future in either case.
                    #   We might want to consider using Future->try somehow instead.
                    try {
                        # deposit to Binary a/c
                        my ($txn) = $to_client->payment_mt5_transfer(
                            amount   => $mt5_amount,
                            currency => $to_client->currency,
                            staff    => $to_loginid,
                            remark   => $comment,
                            fees     => $fees_in_client_currency,
                            source   => $source,
                        );

                        _record_mt5_transfer($to_client->db->dbic, $txn->payment_id, $amount, $fm_mt5, $mt5_currency_code);

                        BOM::Platform::Event::Emitter::emit(
                            'transfer_between_accounts',
                            {
                                loginid    => $to_client->loginid,
                                properties => {
                                    from_account       => $fm_mt5,
                                    is_from_account_pa => 0 + !!($to_client->is_pa_and_authenticated),
                                    to_account         => $to_loginid,
                                    is_to_account_pa   => 0 + !!($to_client->is_pa_and_authenticated),
                                    from_currency      => $mt5_currency_code,
                                    to_currency        => $to_client->currency,
                                    from_amount        => abs $amount,
                                    to_amount          => $mt5_amount,
                                    source             => $source,
                                    fees               => $fees,
                                    gateway_code       => 'mt5_transfer',
                                    id                 => $txn->{id},
                                    time               => $txn->{transaction_time}}});

                        # TODO (JB): clean up old group name after we have migrated all accounts to new group
                        # - real\vanuatu_financial
                        _store_transaction_redis({
                                loginid       => $to_loginid,
                                mt5_id        => $fm_mt5,
                                action        => 'withdraw',
                                amount_in_USD => $amount,
                            })
                            if ($mt5_group eq 'real\vanuatu_financial'
                            or $mt5_group =~ /real\d{2}\\financial\\vanuatu_std-hr_usd/);

                        return Future->done({
                            status                => 1,
                            binary_transaction_id => $txn->transaction_id
                        });
                    } catch {
                        my $error = BOM::Transaction->format_error(err => $@);
                        log_exception('mt5_withdrawal');
                        _send_email(
                            loginid      => $to_loginid,
                            mt5_id       => $fm_mt5,
                            amount       => $amount,
                            action       => 'withdraw',
                            error        => $error->get_mesg,
                            account_type => $account_type,
                        );
                        return create_error_future($error_code, {message => $error->{-message_to_client}});
                    }
                });
        });
    };

sub _get_mt5_account_from_affiliate_token {
    my $args = shift;

    my ($user, $account_type, $country, $token, $market) =
        @{$args}{qw(user account_type country token market)};

    my $agent_id;

    if ($token) {
        my $aff = WebService::MyAffiliates->new(
            user    => BOM::Config::third_party()->{myaffiliates}->{user},
            pass    => BOM::Config::third_party()->{myaffiliates}->{pass},
            host    => BOM::Config::third_party()->{myaffiliates}->{host},
            timeout => 10
            )
            or do {
            stats_inc('myaffiliates.mt5.failure.connect', 1);
            return 0;
            };

        my $myaffiliate_id = $aff->get_affiliate_id_from_token($token) or do {
            stats_inc('myaffiliates.mt5.failure.get_aff_id', 1);
            return 0;
        };

        my $server_id = _get_server_type($account_type, $country, $market);

        ($agent_id) = $user->dbic->run(
            fixup => sub {
                $_->selectrow_array(q{SELECT * FROM mt5.get_agent_id(?, ?)}, undef, $myaffiliate_id, $server_id);
            });

        if (not $agent_id) {
            stats_inc('myaffiliates.mt5.failure.no_info', 1);
            return 0;
        }
    }

    return $agent_id;
}

sub _mt5_validate_and_get_amount {
    my ($authorized_client, $loginid, $mt5_loginid, $amount, $error_code, $currency_check) = @_;
    my $brand_name = request()->brand->name;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    return create_error_future('PaymentsSuspended', {override_code => $error_code})
        if ($app_config->system->suspend->payments);

    my $mt5_transfer_limits = BOM::Config::CurrencyConfig::mt5_transfer_limits($brand_name);

    # MT5 login or binary loginid not belongs to user
    my @loginids_list = ($mt5_loginid);
    push @loginids_list, $loginid if $loginid;

    return create_error_future('permission') unless _check_logins($authorized_client, \@loginids_list);

    return _get_user_with_group($mt5_loginid)->then(
        sub {
            my ($setting) = @_;
            return create_error_future(
                'NoAccountDetails',
                {
                    override_code => $error_code,
                    params        => $mt5_loginid
                }) if (ref $setting eq 'HASH' && $setting->{error});

            my $action             = ($error_code =~ /Withdrawal/) ? 'withdrawal' : 'deposit';
            my $action_counterpart = ($error_code =~ /Withdrawal/) ? 'deposit'    : 'withdraw';

            my $mt5_group = $setting->{group};
            my $mt5_lc    = _fetch_mt5_lc($setting);
            return create_error_future('InvalidMT5Group') unless $mt5_lc;

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
                return create_error_future('FinancialAssessmentMandatory', {override_code => $error_code});
            }

            return create_error_future($setting->{status}->{withdrawal_locked}->{error}, {override_code => $error_code})
                if ($action eq 'withdrawal' and $setting->{status}->{withdrawal_locked});

            my $mt5_currency = $setting->{currency};
            return create_error_future('CurrencyConflict', {override_code => $error_code})
                if $currency_check && $currency_check ne $mt5_currency;

            # Check if id is a demo account
            # If yes, then no need to validate client
            if (_is_account_demo($mt5_group)) {
                return create_error_future('NoDemoWithdrawals', {override_code => $error_code})
                    if $action eq 'withdrawal';

                return create_error_future('TransferBetweenAccountsError', {override_code => $error_code})
                    if $action eq 'deposit' and $loginid;

                my $max_balance_before_topup = BOM::Config::payment_agent()->{minimum_topup_balance}->{DEFAULT};

                return create_error_future(
                    'DemoTopupBalance',
                    {
                        override_code => $error_code,
                        params        => [formatnumber('amount', $mt5_currency, $max_balance_before_topup), $mt5_currency]}
                ) if ($setting->{balance} > $max_balance_before_topup);

                if (_throttle($mt5_loginid)) {
                    return create_error_future('DemoTopupThrottle', {override_code => $error_code});
                }

                return Future->done({top_up_virtual => 1});

            }

            return create_error_future('MissingID', {override_code => $error_code}) unless $loginid;

            return create_error_future('MissingAmount', {override_code => $error_code}) unless $amount;

            return create_error_future('WrongAmount', {override_code => $error_code}) if ($amount <= 0);

            my $client;
            try {
                $client = BOM::User::Client->new({
                    loginid      => $loginid,
                    db_operation => 'replica'
                });

            } catch {
                log_exception();
                return create_error_future(
                    'InvalidLoginid',
                    {
                        override_code => $error_code,
                        params        => $loginid
                    });
            }

            # Validate the binary client
            my ($err, $params) = _validate_client($client, $mt5_lc);
            return create_error_future(
                $err,
                {
                    override_code => $error_code,
                    params        => $params
                }) if $err;

            #  Not allow virtual token/oauth to process with real account.
            return create_error_future('permission') if $authorized_client->is_virtual and not $client->is_virtual;

            my $client_currency = $client->account ? $client->account->currency_code() : undef;
            return create_error_future('TransferBetweenDifferentCurrencies')
                unless $client_currency eq $mt5_currency || $client->landing_company->mt5_transfer_with_different_currency_allowed;

            my $brand = Brands->new(name => request()->brand);

            return create_error_future(
                'WithdrawalLocked',
                {
                    override_code => $error_code,
                    params        => $brand->emails('support')})
                if ($action eq 'deposit'
                and ($client->status->no_withdrawal_or_trading or $client->status->withdrawal_locked));

            # Deposit should be locked if mt5 vanuatu/labuan account is disabled
            if (    $action eq 'deposit'
                and $mt5_group =~ /(?:labuan|vanuatu)/)
            {
                my $hex_rights   = BOM::Config::mt5_user_rights()->{'rights'};
                my %known_rights = map { $_ => hex $hex_rights->{$_} } keys %$hex_rights;
                my %rights       = map { $_ => $setting->{rights} & $known_rights{$_} ? 1 : 0 } keys %known_rights;
                if (not $rights{enabled} or $rights{trade_disabled}) {
                    return create_error_future('MT5DepositLocked');
                }
            }

            # Actual USD or EUR amount that will be deposited into the MT5 account.
            # We have a currency conversion fees when transferring between currencies.
            my $mt5_amount = undef;

            my $source_currency = $client_currency;

            my $mt5_currency_type    = LandingCompany::Registry::get_currency_type($mt5_currency);
            my $source_currency_type = LandingCompany::Registry::get_currency_type($source_currency);

            return create_error_future('TransferSuspended', {override_code => $error_code})
                if BOM::Config::Runtime->instance->app_config->system->suspend->transfer_between_accounts
                and (($source_currency_type // '') ne ($mt5_currency_type // ''));

            return create_error_future('TransfersBlocked', {message => localize("Transfers are not allowed for these accounts.")})
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
                return create_error_future('NoExchangeRates');
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

                return create_error_future(
                    'CurrencySuspended',
                    {
                        override_code => $error_code,
                        params        => [$source_currency, $mt5_currency]}
                ) if first { $_ eq $source_currency or $_ eq $mt5_currency } @$disabled_for_transfer_currencies;

                if ($action eq 'deposit') {

                    try {
                        ($mt5_amount, $fees, $fees_percent, $min_fee, $fee_calculated_by_percent) =
                            BOM::Platform::Client::CashierValidation::calculate_to_amount_with_fees($amount, $client_currency, $mt5_currency);

                        $mt5_amount = financialrounding('amount', $mt5_currency, $mt5_amount);

                    } catch {
                        log_exception();
                        # usually we get here when convert_currency() fails to find a rate within $rate_expiry, $mt5_amount is too low, or no transfer fee are defined (invalid currency pair).
                        $err        = $@;
                        $mt5_amount = undef;
                    }

                } elsif ($action eq 'withdrawal') {

                    try {

                        $source_currency = $mt5_currency;

                        ($mt5_amount, $fees, $fees_percent, $min_fee, $fee_calculated_by_percent) =
                            BOM::Platform::Client::CashierValidation::calculate_to_amount_with_fees($amount, $mt5_currency, $client_currency);

                        $mt5_amount = financialrounding('amount', $client_currency, $mt5_amount);

                        # if last rate is expiered calculate_to_amount_with_fees would fail.
                        $fees_in_client_currency =
                            financialrounding('amount', $client_currency, convert_currency($fees, $mt5_currency, $client_currency));
                    } catch {
                        log_exception();
                        # same as previous catch
                        $err = $@;
                    }
                }
            }

            if ($err) {
                return create_error_future(Date::Utility->new->is_a_weekend ? 'ClosedMarket' : 'NoExchangeRates', {override_code => $error_code})
                    if ($err =~ /No rate available to convert/);

                return create_error_future(
                    'NoTransferFee',
                    {
                        override_code => $error_code,
                        params        => [$client_currency, $mt5_currency]}) if ($err =~ /No transfer fee/);

                # Lower than min_unit in the receiving currency. The lower-bounds are not uptodate, otherwise we should not accept the amount in sending currency.
                # To update them, transfer_between_accounts_fees is called again with force_refresh on.
                return create_error_future(
                    'AmountNotAllowed',
                    {
                        override_code => $error_code,
                        params        => [$mt5_transfer_limits->{$source_currency}->{min}, $source_currency]}
                ) if ($err =~ /The amount .* is below the minimum allowed amount/);

                #default error:
                return create_error_future($error_code);
            }

            $err = BOM::RPC::v3::Cashier::validate_amount($amount, $source_currency);
            return create_error_future($error_code, {message => $err}) if $err;

            my $min = $mt5_transfer_limits->{$source_currency}->{min};

            return create_error_future(
                'InvalidMinAmount',
                {
                    override_code => $error_code,
                    params        => [formatnumber('amount', $source_currency, $min), $source_currency]}
            ) if $amount < financialrounding('amount', $source_currency, $min);

            my $max = $mt5_transfer_limits->{$source_currency}->{max};

            return create_error_future(
                'InvalidMaxAmount',
                {
                    override_code => $error_code,
                    params        => [formatnumber('amount', $source_currency, $max), $source_currency]}
            ) if $amount > financialrounding('amount', $source_currency, $max);

            my $validation = BOM::Platform::Client::CashierValidation::validate($loginid, $action_counterpart);
            return create_error_future($error_code, {message => $validation->{error}->{message_to_client}}) if exists $validation->{error};

            return Future->done({
                mt5_amount              => $mt5_amount,
                fees                    => $fees,
                fees_currency           => $source_currency,
                fees_percent            => $fees_percent,
                fees_in_client_currency => $fees_in_client_currency,
                mt5_currency_code       => $mt5_currency,
                min_fee                 => $min_fee,
                calculated_fee          => $fee_calculated_by_percent,
                mt5_data                => $setting
            });
        });
}

sub _fetch_mt5_lc {
    my $settings = shift;

    my $group_params = parse_mt5_group($settings->{group});

    return undef unless $group_params->{landing_company_short};

    my $landing_company = LandingCompany::Registry::get($group_params->{landing_company_short});

    return undef unless $landing_company;

    return $landing_company;
}

sub _mt5_has_open_positions {
    my $login = shift;

    return BOM::MT5::User::Async::get_open_positions_count($login)->then(
        sub {
            my ($response) = @_;
            return create_error_future('CannotGetOpenPositions')
                if (ref $response eq 'HASH' and $response->{error});

            return Future->done($response->{total} ? 1 : 0);
        })->catch($error_handler);
}

=head2 _record_mt5_transfer

Writes an entry into the mt5_transfer table
Takes the following arguments as named parameters

=over 4

=item * DBIC  Database handle
=item * payment_id Primary key of the payment table entry
=item * mt5_amount   Amount sent to MT5 in the MT5 currency
=item * mt5_account_id the clients MT5 account id
=item * mt5_currency_code  Currency Code of the lcients MT5 account.

=back

Returns 1

=cut

sub _record_mt5_transfer {
    my ($dbic, $payment_id, $mt5_amount, $mt5_account_id, $mt5_currency_code) = @_;

    $dbic->run(
        fixup => sub {
            my $sth = $_->prepare(
                'INSERT INTO payment.mt5_transfer
            (payment_id, mt5_amount, mt5_account_id, mt5_currency_code)
            VALUES (?,?,?,?)'
            );
            $sth->execute($payment_id, $mt5_amount, $mt5_account_id, $mt5_currency_code);
        });
    return 1;
}

sub _store_transaction_redis {
    my $data = shift;
    BOM::Platform::Event::Emitter::emit('store_mt5_transaction', $data);
    return;
}

=head2 _validate_client

Validate the client account, which is involved in real-money deposit/withdrawal

=cut

sub _validate_client {
    my ($client_obj, $mt5_lc) = @_;

    my $loginid = $client_obj->loginid;

    # only for real money account
    return 'VirtualProhibited' if ($client_obj->is_virtual);

    my $lc = $client_obj->landing_company->short;

    # Landing companies listed below are an exception for this check as
    # they have mutual agreement and it is allowed to transfer funds
    # through gaming/financial MT5 accounts:
    # - transfers between maltainvest and malta
    # - svg, vanuatu, and labuan

    my $mt5_lc_short = $mt5_lc->short;

    unless (($lc eq 'svg' and ($mt5_lc_short eq 'vanuatu' or $mt5_lc_short eq 'labuan'))
        or ($lc eq 'maltainvest' and $mt5_lc_short eq 'malta')
        or ($lc eq 'malta'       and $mt5_lc_short eq 'maltainvest')
        or $mt5_lc_short eq $lc)
    {
        # Otherwise, Financial accounts should not be able to deposit to, or withdraw from, gaming MT5
        return 'SwitchAccount';
    }

    # Deposits and withdrawals are blocked for non-authenticated MF clients
    return ('AuthenticateAccount', $loginid)
        if ($lc eq 'maltainvest' and not $client_obj->fully_authenticated);

    return ('AccountDisabled', $loginid) if ($client_obj->status->disabled);

    return ('CashierLocked', $loginid)
        if ($client_obj->status->cashier_locked);

    # check if binary client expired documents
    # documents_expired check internaly if landing company
    # needs expired documents check or not
    return ('ExpiredDocuments', request()->brand->emails('support')) if ($client_obj->documents_expired());

    # if mt5 financial accounts is used for deposit or withdraw
    # then check if client has valid documents or not
    # valid documents don't have additional landing companies check
    # that we have in documents_expired
    # TODO: Remove this once we have async mt5 in place
    return ('ExpiredDocuments', request()->brand->emails('support'))
        if ($mt5_lc->documents_expiration_check_required() and not $client_obj->has_valid_documents());

    my $client_currency = $client_obj->account ? $client_obj->account->currency_code() : undef;
    return ('SetExistingAccountCurrency', $loginid) unless $client_currency;

    my $daily_transfer_limit      = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->MT5;
    my $user_daily_transfer_count = $client_obj->user->daily_transfer_count('mt5');

    return ('MaximumTransfers', $daily_transfer_limit)
        unless $user_daily_transfer_count < $daily_transfer_limit;

    return undef;
}

sub _is_account_demo {
    my ($group) = @_;
    return $group =~ /demo/;
}

sub do_mt5_deposit {
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
            log_exception('mt5_deposit') if $txn_id;
            $error_handler->($e);
        });
}

sub do_mt5_withdrawal {
    my ($login, $amount, $comment) = @_;
    my $withdrawal_sub = \&BOM::MT5::User::Async::withdrawal;

    return $withdrawal_sub->({
            login   => $login,
            amount  => $amount,
            comment => $comment,
        })->catch($error_handler);
}

sub _generate_password {
    my ($seed_str) = @_;
    # The password must contain at least two of three types of characters (lower case, upper case and digits)
    # We are not using random string for future usage consideration
    my $pwd = substr(sha384_hex($seed_str . 'E3xsTE6BQ=='), 0, 20);
    return $pwd . 'Hx_0';
}

sub _is_identical_group {
    my ($group, $existing_groups) = @_;

    my $group_config = get_mt5_account_type_config($group);

    foreach my $existing_group (map { get_mt5_account_type_config($_) } keys %$existing_groups) {
        return $existing_group if defined $existing_group and all { $group_config->{$_} eq $existing_group->{$_} } keys %$group_config;
    }

    return undef;
}

sub _is_similar_group {
    my ($landing_company_short, $existing_group) = @_;

    my $similar_company = $landing_company_short eq 'vanuatu' ? 'svg' : $landing_company_short eq 'svg' ? 'vanuatu' : undef;

    return undef unless $similar_company;

    my $first =
        first { $_ =~ /^real\\${similar_company}_financial(?:_Bbook)?$/ || $_ =~ /^real\d{2}\\financial\\${similar_company}_std(?:-hr)?_usd$/ }
    keys %$existing_group;

    return $first;
}

1;
