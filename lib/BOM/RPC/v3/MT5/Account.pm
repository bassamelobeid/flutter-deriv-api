package BOM::RPC::v3::MT5::Account;

use strict;
use warnings;

no indirect;

use YAML::XS;
use Date::Utility;
use List::Util qw(any first all sum);
use Syntax::Keyword::Try;
use File::ShareDir;
use Locale::Country::Extra;
use WebService::MyAffiliates;
use Format::Util::Numbers qw/financialrounding formatnumber/;
use JSON::MaybeUTF8 qw(decode_json_utf8);
use DataDog::DogStatsd::Helper qw(stats_inc stats_event);
use Digest::SHA qw(sha384_hex);
use LandingCompany::Registry;
use ExchangeRates::CurrencyConverter qw/convert_currency offer_to_clients/;
use Log::Any qw($log);
use Locale::Country qw(country2code);
use Brands::Countries;

use BOM::RPC::Registry '-dsl';
use BOM::RPC::v3::MT5::Errors;
use BOM::RPC::v3::Utility qw(log_exception);
use BOM::RPC::v3::Cashier;
use BOM::RPC::v3::Accounts;
use BOM::Config;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Utility;
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
use BOM::Config::MT5;

requires_auth('wallet', 'trading');

use constant MT5_ACCOUNT_THROTTLE_KEY_PREFIX => 'MT5ACCOUNT::THROTTLE::';

use constant MT5_MALTAINVEST_MOCK_LEVERAGE => 33;
use constant MT5_MALTAINVEST_REAL_LEVERAGE => 30;

use constant MT5_SVG_FINANCIAL_MOCK_LEVERAGE => 1;
use constant MT5_SVG_FINANCIAL_REAL_LEVERAGE => 1000;

use constant MT5_VIRTUAL_MONEY_DEPOSIT_COMMENT => 'MT5 Virtual Money deposit';

use constant USER_RIGHT_ENABLED        => 0x0000000000000001;
use constant USER_RIGHT_TRAILING       => 0x0000000000000020;
use constant USER_RIGHT_EXPERT         => 0x0000000000000040;
use constant USER_RIGHT_API            => 0x0000000000000080;
use constant USER_RIGHT_REPORTS        => 0x0000000000000100;
use constant USER_RIGHT_TRADE_DISABLED => 0x0000000000000004;

# This is the default trading server key for
# - demo account
# - real financial and financial stp accounts
# - countries that is not defined in BOM::Config::mt5_server_routing()
my $DEFAULT_TRADING_SERVER_KEY = 'p01_ts01';

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

=head2 get_mt5_server_list

    get_mt5_server_list(residence => $client->residence, account_type => 'real', market_type => 'synthetic');

Return the array of hash of trade servers configuration
as per schema defined

=cut

sub get_mt5_server_list {
    my (%args) = @_;

    return Future->done([]) unless $args{residence};

    my $brand = Brands::Countries->new;

    return Future->done([]) if $brand->restricted_country($args{residence});

    my $mt5_config = BOM::Config::MT5->new();

    my $server_list = $mt5_config->server_by_country(
        $args{residence},
        {
            group_type  => $args{account_type},
            market_type => $args{market_type}});

    my $mt5_account_count = $brand->mt_account_count_for_country(country => $args{residence});
    $mt5_account_count->{synthetic} = delete $mt5_account_count->{gaming};

    return get_mt5_logins($args{client}, $args{account_type})->then(
        sub {
            my @mt5_logins = @_;

            my @valid_servers;
            foreach my $group_type (keys %$server_list) {
                foreach my $market_type (keys %{$server_list->{$group_type}}) {
                    my $servers = $server_list->{$group_type}{$market_type};
                    foreach my $server (@$servers) {

                        # if trade server API call is disabled, we add message_to_client
                        if ($server->{disabled}) {
                            $server->{message_to_client} = localize('Temporarily unavailable');
                        }

                        my $created_mt5_accounts =
                            scalar(grep { defined $_->{group} and $_->{group} =~ /^$group_type\\$server->{id}\\$market_type\\/ } @mt5_logins);

                        if ($created_mt5_accounts >= $mt5_account_count->{$market_type}) {
                            $server->{disabled}          = 1;
                            $server->{message_to_client} = localize('Region added');
                        }

                        $server->{market_type}  = $market_type;
                        $server->{account_type} = $group_type;
                        push @valid_servers, $server;
                    }
                }
            }
            return Future->done(\@valid_servers);
        });

}

=head2 get_mt5_logins

$mt5_logins = get_mt5_logins($client)

Takes Client object and fetch all its available and active MT5 accounts

Takes the following parameter:

=over 4

=item * C<params> hashref that contains a C<BOM::User::Client>

=item * C<params> string to represent account type (gaming|demo|financial) or default to undefined.

=back

Returns a Future holding list of MT5 account information or a failed future with error information

=cut

sub get_mt5_logins {
    my ($client, $account_type) = @_;

    return mt5_accounts_lookup($client, $account_type)->then(
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

=item * C<params> string to represent account type (gaming|demo|financial) or default to undefined.

=back

Returns a Future holding list of MT5 account information (or undef) or a failed future with error information

=cut

sub mt5_accounts_lookup {
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
    for my $login ($client->user->get_mt5_loginids($account_type)) {
        my $f = mt5_get_settings({
                client => $client,
                args   => {login => $login}}
        )->then(
            sub {
                my ($setting) = @_;

                $setting = _filter_settings($setting,
                    qw/account_type balance country currency display_balance email group landing_company_short leverage login name market_type sub_account_type server server_info/
                ) if !$setting->{error};
                return Future->done($setting);
            }
        )->catch(
            sub {
                my ($resp) = @_;

                if ((
                        ref $resp eq 'HASH' && defined $resp->{error} && ref $resp->{error} eq 'HASH' && ($allowed_error_codes{$resp->{error}{code}}
                            || $allowed_error_codes{$resp->{error}{message_to_client}}))
                    || $allowed_error_codes{$resp})
                {
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
sub_account_type: std[standard]|hf[high-risk]
currency: usd|gbp|...

How does this map to the input?

account_type:     demo|gaming|financial
mt5_account_type  financial|financial_stp
mt5_account_category: conventional|empty for financial_stp

=cut

sub _mt5_group {
    my $args = shift;

    my ($landing_company_short, $account_type, $mt5_account_type, $currency, $account_category, $country, $user_input_trade_server, $restricted_group)
        = @{$args}{qw(landing_company_short account_type mt5_account_type currency sub_account_type country server restricted_group)};

    my ($server_type, $sub_account_type, $group_type);

    # affiliate LC should map to seychelles
    my $lc = LandingCompany::Registry->by_name($landing_company_short);
    return 'real\p02_ts02\synthetic\seychelles_ib_usd' if $lc->is_for_affiliates();

    my $market_type = _get_market_type($account_type, $mt5_account_type);

    if ($account_type eq 'demo') {
        $group_type       = $account_type;
        $server_type      = _get_server_type($account_type, $country, $market_type);
        $sub_account_type = _get_sub_account_type($mt5_account_type, $account_category);
    } else {
        # real group mapping
        $account_type     = 'real';
        $group_type       = $account_type;
        $server_type      = _get_server_type($account_type, $country, $market_type);
        $sub_account_type = _get_sub_account_type($mt5_account_type, $account_category);
        # All svg financial account will be B-book (put in hr[high-risk] upon sign-up. Decisions to A-book will be done
        # on a case by case basis manually
        my $app_config = BOM::Config::Runtime->instance->app_config;
        # only consider b-booking financial for svg
        my $apply_auto_b_book =
            ($market_type eq 'financial' and $landing_company_short eq 'svg' and not $app_config->system->mt5->suspend->auto_Bbook_svg_financial);
        # as per requirements of mt5 operation team, australian financial account will not be categorised as high-risk (hr)
        $sub_account_type .= '-hr' if $market_type eq 'financial' and $country ne 'au' and $sub_account_type ne 'stp' and not $apply_auto_b_book;

        # make the sub account type ib for affiliate accounts
        $sub_account_type = 'ib' if $lc->is_for_affiliates();
    }

    # restricted trading group
    $sub_account_type .= '-lim' if $restricted_group;

    # TODO (JB): Refactor this.
    # - user is only allowed to create account on real02, real03 and real04 if he/she is not from Ireland trade server country list ($server_type = $DEFAULT_TRADING_SERVER_KEY)
    # - user from Ireland trade server country list will be allowed to create account on real01, real02, real03 and real04
    return ''
        if (defined $user_input_trade_server
        and $server_type ne $DEFAULT_TRADING_SERVER_KEY
        and $user_input_trade_server eq $DEFAULT_TRADING_SERVER_KEY);

    # We only have a sub-group for a specific group (real\synthetic\svg_std_usd). We believed MT5 can't handle too many
    # accounts in the real group despite having the similar account numbers in demo server. So, just do it.
    # We have four sub-groups (01, 02, 03 & 04) and the accounts are randomly distributed.
    my $sub_group;
    if (    $landing_company_short eq 'svg'
        and $sub_account_type eq 'std'
        and lc($currency) eq 'usd'
        and $market_type eq 'synthetic'
        and $group_type eq 'real')
    {
        my $rand = 1 + int(rand(4));
        $sub_group = '0' . $rand;
    }

    if ($user_input_trade_server) {
        $server_type = $user_input_trade_server;
    }

    my @group_bits =
        ($group_type, $server_type, $market_type, join('_', ($landing_company_short, $sub_account_type, $currency)));
    push @group_bits, $sub_group if defined $sub_group;
    # just making sure everything is lower case!

    return lc(join('\\', @group_bits));
}

=head2 _get_server_type

Returns key of trading server that corresponds to the account type(demo/real) and country

=over 4

=item * account type

=item * country

=item * market_type

=back

Takes the following parameters:

=over 4

=item * C<$account_type> - string representing type of the MT5 sevrer (demo/real)

=item * C<$country> - Alpha-2 code of the country

=back

Returns a randomly selected trading server key in client's region

=cut

sub _get_server_type {
    my ($account_type, $country, $market_type) = @_;

    my $server_routing_config = BOM::Config::mt5_server_routing();

    # just in case we pass in the name of the country instead of the country code.
    if (length $country != 2) {
        $country = country2code($country);
    }

    # if it is not defined, set $server_type to $DEFAULT_TRADING_SERVER_KEY
    # servers is an array reference arranged according to recommended priority
    my $server_type = $server_routing_config->{$account_type}->{$country}->{$market_type}->{servers}->[0];
    if (not defined $server_type) {
        $log->warnf("Routing config is missing for %s %s-%s", uc($country), $account_type, $market_type) if $account_type ne 'demo';
        $server_type = $DEFAULT_TRADING_SERVER_KEY;
    }

    my $servers = BOM::Config::MT5->new(
        group_type  => $account_type,
        server_type => $server_type
    )->symmetrical_servers();

    return _select_server($servers, $account_type);
}

=head2 _select_server

Based on the runtime config file, select one server from servers hashref

=over 4

=item * C<$servers> - A hashref contains servers as keys such as p01_ts01

=item * C<$account_type>

=back

Returns string containing the selected server key

=cut

sub _select_server {
    my ($servers, $account_type) = @_;

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

    # if none of the trade servers are available, we will return the default trade server key,
    # this could be unavailable as well but this method cannot returns undef
    unless (@selected_servers) {
        return $DEFAULT_TRADING_SERVER_KEY;
    }

    # just return if this is the only trade server available
    return $selected_servers[0][0] if @selected_servers == 1;
    # if we have more than on trade servers, we distribute the load according to the weight specified
    # in the backoffice settings
    my @servers;
    foreach my $server (sort { $a->[1] <=> $b->[1] } @selected_servers) {
        push @servers, map { $server->[0] } (1 .. $server->[1]);
    }

    return $servers[int(_rand(@servers))] if @servers;

    $log->warnf("something is wrong with mt5 server selection, returning default trade server.");

    return $DEFAULT_TRADING_SERVER_KEY;
}

=head2 _rand

Returns a random number from 0 to 1.

Mainly for testing

=cut

sub _rand {
    my @servers = @_;
    return rand(@servers);
}

=head2 _get_sub_account_type

Returns sub account type that corresponds to the mt5 account type and account category.

Takes the following parameters:

=over 4

=item * C<$mt5_account_type> - string representing the mt5 account type (financial|financial_stp)

=back

=cut

sub _get_sub_account_type {
    my ($mt5_account_type) = @_;

    # $sub_account_type depends on $mt5_account_type and $account_category. It is a little confusing, but can't do much about it.
    my $sub_account_type = 'std';
    if (defined $mt5_account_type and $mt5_account_type eq 'financial_stp') {
        $sub_account_type = 'stp';
    }

    return $sub_account_type;
}

async_rpc "mt5_new_account",
    category => 'mt5',
    sub {
    my $params      = shift;
    my $brand       = request()->brand;
    my $contact_url = $brand->contact_url({
            source   => $params->{source},
            language => $params->{language}});

    my $error_code = 'MT5CreateUserError';

    my ($client, $args) = @{$params}{qw/client args/};

    # extract request parameters
    my $account_type            = delete $args->{account_type};
    my $mt5_account_type        = delete $args->{mt5_account_type}     // '';
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
    $mt5_account_category = '' if $mt5_account_type eq 'financial_stp' or $mt5_account_category !~ /^conventional$/;

    my $passwd_validation_err = BOM::RPC::v3::Utility::validate_mt5_password({
        email           => $client->email,
        main_password   => $args->{mainPassword}   // '',
        invest_password => $args->{investPassword} // '',
    });
    return create_error_future($passwd_validation_err) if $passwd_validation_err;

    my $trading_password = $args->{mainPassword};

    unless ($args->{dry_run}) {
        if (my $current_password = $client->user->trading_password) {
            my $error = BOM::RPC::v3::Utility::validate_password_with_attempts($trading_password, $current_password, $client->loginid);
            return create_error_future($error) if $error;
        }
    }

    $args->{investPassword} = _generate_password($trading_password) unless $args->{investPassword};

    return create_error_future('InvalidSubAccountType')
        if ($mt5_account_type and $mt5_account_type !~ /^financial|financial_stp/)
        or ($account_type eq 'financial' and $mt5_account_type eq '');

    # legal validation
    my $residence = $client->residence;

    my $countries_instance = $brand->countries_instance;
    my $countries_list     = $countries_instance->countries_list;
    return create_error_future('InvalidAccountRegion') unless $countries_list->{$residence} && $countries_instance->is_signup_allowed($residence);

    my $user = $client->user;

    # demo accounts type determined if this parameter exists or not
    my $company_type     = $mt5_account_type eq '' ? 'gaming' : 'financial';
    my $sub_account_type = $mt5_account_type;
    my %mt_args          = (
        country          => $residence,
        account_type     => $company_type,
        sub_account_type => $sub_account_type
    );
    my $company_name = _get_mt_landing_company($client, \%mt_args);

    if (defined $user_input_trade_server && ($company_name eq 'malta' || $company_name eq 'maltainvest')) {
        return create_error_future('InvalidServerInput');
    }
    # MT5 is not allowed in client country
    return create_error_future($mt5_account_category eq 'swap_free' ? 'MT5SwapFreeNotAllowed' : 'MT5NotAllowed', {params => $company_type})
        if $company_name eq 'none';

    my $binary_company_name = _get_landing_company($client, $company_type);

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

    return create_error_future('AccountTypesMismatch') if ($client->is_virtual() and $account_type ne 'demo');

    my $requirements        = LandingCompany::Registry->by_name($company_name)->requirements;
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
    # If the default currency is not in the $landing_company->available_mt5_currency_group, it will be directed to the first available currency.
    #
    # A practical example:
    # - MF (residence: germany) client with selected account currency of USD. The mt5 account currency will be EUR.
    # - MF (residence: germany) client with selected account currency of GBP. The mt5 account currency will be GBP.
    # - SVG (residence: australia) client with selected account current of AUD. The mt5 account currency will be USD.
    my $default_currency       = LandingCompany::Registry->by_name($company_name)->get_default_currency($residence);
    my $available              = $client->landing_company->available_mt5_currency_group();
    my %available_mt5_currency = map { $_ => 1 } @$available;

    # For virtual account, because we have clients from svg, malta and maltainvest under the same virtual
    # landing company, we will stick to $default_currency in mt5 group selection.
    my $selected_currency =
          ($account_type ne 'demo' && $available_mt5_currency{$client->currency}) ? $client->currency
        : $available_mt5_currency{$default_currency}                              ? $default_currency
        :                                                                           $available->[0];
    my $mt5_account_currency = $args->{currency} // $selected_currency;

    return create_error_future('permission') if $mt5_account_currency ne $selected_currency;

    my $group = _mt5_group({
        country               => $residence,
        landing_company_short => $company_name,
        account_type          => $account_type,
        mt5_account_type      => $mt5_account_type,
        currency              => $mt5_account_currency,
        sub_account_type      => $mt5_account_category,
        server                => $user_input_trade_server,
        restricted_group      => $countries_instance->is_mt5_restricted_group($residence),
    });

    my $group_config = get_mt5_account_type_config($group);

    # something is wrong if we're not able to get group config
    return create_error_future('permission') unless $group_config;

    my $compliance_requirements = $requirements->{compliance};

    if ($group !~ /^demo/) {
        return create_error_future('FinancialAssessmentRequired')
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

    my %mt5_compliance_requirements = map { ($_ => 1) } $compliance_requirements->{mt5}->@*;
    if ($account_type ne 'demo' && $mt5_compliance_requirements{fully_authenticated}) {
        if ($client->fully_authenticated) {
            if ($mt5_compliance_requirements{expiration_check} && $client->documents->expired(1)) {
                $client->status->upsert('allow_document_upload', 'system', 'MT5_ACCOUNT_IS_CREATED');
                return create_error_future('ExpiredDocumentsMT5', {params => $client->loginid});
            }
        } else {
            $client->status->upsert('allow_document_upload', 'system', 'MT5_ACCOUNT_IS_CREATED');
            return create_error_future('AuthenticateAccount', {params => $client->loginid});
        }
    }

    if (    $client->tax_residence
        and $account_type ne 'demo'
        and $group =~ /real(?:\\p\d{2}_ts)?\d{2}\\financial\\(?:labuan|bvi)_stp_usd/)
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

    if ($args->{dry_run}) {
        return Future->done({
                account_type    => $account_type,
                balance         => 0,
                currency        => 'USD',
                display_balance => '0.00',
                ($mt5_account_type) ? (mt5_account_type => $mt5_account_type) : ()});
    }

    # Check if client is throttled before sending MT5 request
    if (_throttle($client->loginid)) {
        return create_error_future('MT5AccountCreationThrottle', {override_code => $error_code});
    }

    # don't allow new mt5 account creation without trading password
    return create_error_future('TradingPasswordRequired',
        {message => localize('Please set your MT5 password using the [_1] API.', 'trading_platform_password_change')})
        unless $client->user->trading_password;

    # disable trading for affiliate accounts
    if ($client->landing_company->is_for_affiliates) {
        $args->{rights} = USER_RIGHT_TRADE_DISABLED;
    }

    # disable trading for payment agents
    if (defined $client->payment_agent && $client->payment_agent->status eq 'authorized') {
        $args->{rights} =
            USER_RIGHT_ENABLED | USER_RIGHT_TRAILING | USER_RIGHT_EXPERT | USER_RIGHT_API | USER_RIGHT_REPORTS | USER_RIGHT_TRADE_DISABLED;
    }

    return get_mt5_logins($client, $account_type)->then(
        sub {
            my (@logins) = @_;

            my %existing_groups;
            my $trade_server_error;
            my $has_hr_account = undef;
            foreach my $mt5_account (@logins) {
                if ($mt5_account->{error} and $mt5_account->{error}{code} eq 'MT5AccountInaccessible') {
                    $trade_server_error = $mt5_account->{error};
                    last;
                }

                $existing_groups{$mt5_account->{group}} = $mt5_account->{login} if $mt5_account->{group};

                $has_hr_account = 1 if lc($mt5_account->{group}) =~ /synthetic/ and lc($mt5_account->{group}) =~ /(\-hr|highrisk)/;
            }

            if ($trade_server_error) {

                return create_error_future(
                    'MT5AccountCreationSuspended',
                    {
                        override_code => $error_code,
                        message       => $trade_server_error->{message_to_client},
                    });
            }

            # If one of client's account has been moved to high-risk groups
            # client shouldn't be able to open a non high-risk account anymore
            # so, here we set convert the group to high-risk version of the selected group if applicable
            if ($has_hr_account and $account_type ne 'demo' and $group =~ /synthetic/ and not $group =~ /\-/) {
                my ($division) = $group =~ /\\[a-zA-Z]+_([a-zA-Z]+)_/;
                my $new_group = $group =~ s/$division/$division-hr/r;

                # We don't have counter for svg hr groups.
                # Remove it from group name if the original has it
                $new_group =~ s/\\\d+$//;

                if (get_mt5_account_type_config($new_group)) {
                    $group = $new_group;
                } else {
                    $log->warnf("Unable to find high risk group %s for client %s with original group of %s.", $new_group, $client->loginid, $group);

                    return create_error_future('MT5CreateUserError');
                }
            }

            # Can't create account on the same group. We have subgroups which are identical
            # - real\p01_ts01\synthetic\svg_std_usd\01
            # - real\p01_ts01\synthetic\svg_std_usd\02
            if (my $identical = _is_identical_group($group, \%existing_groups)) {
                return create_error_future(
                    'MT5Duplicate',
                    {
                        override_code => $error_code,
                        params        => [$account_type, $existing_groups{$identical}]});
            }

            # A client can only have either one of
            # real\vanuatu_financial or real\svg_financial or real\svg_financial_Bbook
            if ($mt5_account_type eq 'financial') {
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
                        my $ib_affiliate_id = _get_ib_affiliate_id_from_token($client->myaffiliates_token);

                        if ($ib_affiliate_id) {
                            my $agent_login = _get_mt5_agent_account_id({
                                affiliate_id => $ib_affiliate_id,
                                user         => $user,
                                server       => $group_config->{server},
                            });
                            $args->{agent} = $agent_login if $agent_login;
                            $log->warnf("Unable to link %s MT5 account with myaffiliates id %s", $client->loginid, $ib_affiliate_id)
                                unless $agent_login;
                        }
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
                            language         => $params->{language},
                        });

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

=head2 _get_landing_company

Gets the needed Landing Company for the given combination of parameters:

=over 4

=item * C<$client> - The L<BOM::User::Client>  

=item * C<$company_type> - The company type requested.

=back

Returns a landing company short name.

=cut

sub _get_landing_company {
    my ($client, $company_type) = @_;

    return $client->landing_company->short if $client->landing_company->is_for_affiliates;

    my $brand = request()->brand;

    my $countries_instance = $brand->countries_instance;

    my $countries_list = $countries_instance->countries_list;

    my $residence = $client->residence;

    return $countries_list->{$residence}->{"${company_type}_company"};
}

=head2 _get_mt_landing_company

Gets the MT Landing Company for the given combination of parameters:

=over 4

=item * C<$client> - The L<BOM::User::Client>  

=item * C<$args> - hashref of mt5 args including: country, account type and subtype.

=back

Returns a landing company short name.

=cut

sub _get_mt_landing_company {
    my ($client, $args) = @_;

    return $client->landing_company->short if $client->landing_company->is_for_affiliates;

    my $brand = request()->brand;

    my $countries_instance = $brand->countries_instance;

    return $countries_instance->mt_company_for_country($args->%*);
}

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

            return create_error_future('MT5AccountInactive') if !$settings->{active};

            $settings = _filter_settings($settings,
                qw/account_type address balance city company country currency display_balance email group landing_company_short leverage login market_type name phone phonePassword state sub_account_type zipCode server server_info/
            );

            return Future->done($settings);
        })->catch($error_handler);
    };

sub _filter_settings {
    my ($settings, @allowed_keys) = @_;
    my $filtered_settings = {};
    @{$filtered_settings}{@allowed_keys} = @{$settings}{@allowed_keys};
    $filtered_settings->{market_type} = 'synthetic' if $filtered_settings->{market_type} and $filtered_settings->{market_type} eq 'gaming';
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

    if ($config->{server}) {
        my $server_config = BOM::Config::MT5->new(group => $group_name)->server_by_id();
        $settings->{server_info} = {
            id          => $config->{server},
            geolocation => $server_config->{$config->{server}}{geolocation},
            environment => $server_config->{$config->{server}}{environment},
        };
    }
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

    my $args          = $params->{args};
    my $password_type = $args->{password_type} // 'main';

    my $new_api = $password_type eq 'investor' ? 'trading_platform_investor_password_change' : 'trading_platform_password_change';
    return create_error_future('Deprecated',
        {message => localize("To change your [_1] password, please use the [_2] API.", $password_type, $new_api)});
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

    my $args          = $params->{args};
    my $password_type = $args->{password_type} // 'main';

    my $new_api = $password_type eq 'investor' ? 'trading_platform_investor_password_reset' : 'trading_platform_password_reset';
    return create_error_future('Deprecated',
        {message => localize("To reset your [_1] password, please use the [_2] API.", $password_type, $new_api)});
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

                $account_type = $response->{account_type};
            }

            my $fm_client = BOM::User::Client->get_client_instance($fm_loginid, 'write');

            # From the point of view of our system, we're withdrawing
            # money to deposit into MT5
            if ($fm_client->is_virtual) {
                return create_error_future(
                    $error_code,
                    {
                        message => localize("The maximum amount you may transfer is: [_1].", $fm_client->default_account->balance),
                    }) if $amount > $fm_client->default_account->balance;
            } else {
                my $rule_engine = BOM::Rules::Engine->new(client => $fm_client);

                try {
                    $fm_client->validate_payment(
                        currency     => $fm_client->default_account->currency_code(),
                        amount       => -1 * $amount,
                        payment_type => 'mt5_transfer',
                        rule_engine  => $rule_engine,
                    );
                } catch ($e) {
                    return create_error_future(
                        $error_code,
                        {
                            message => $e->{message_to_client},
                        });
                };
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

                # transaction metadata for statement remarks
                my %txn_details = (
                    mt5_account               => $mt5_login_id,
                    fees                      => $fees,
                    fees_percent              => $fees_percent,
                    fees_currency             => $fees_currency,
                    min_fee                   => $min_fee,
                    fee_calculated_by_percent => $fee_calculated_by_percent
                );

                my $additional_comment = BOM::RPC::v3::Cashier::get_transfer_fee_remark(%txn_details);
                $comment = "$comment $additional_comment" if $additional_comment;

                ($txn) = $fm_client->payment_mt5_transfer(
                    amount      => -$amount,
                    currency    => $fm_client->currency,
                    staff       => $fm_loginid,
                    remark      => $comment,
                    fees        => $fees,
                    source      => $source,
                    txn_details => \%txn_details,
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
            } catch ($e) {
                my $error = BOM::Transaction->format_error(err => $e);
                return create_error_future($error_code, {message => $error->{-message_to_client}});
            }

            _store_transaction_redis({
                    loginid       => $fm_loginid,
                    mt5_id        => $to_mt5,
                    action        => 'deposit',
                    amount_in_USD => convert_currency($amount, $fm_client->currency, 'USD'),
                }) if ($response->{mt5_data}->{group} =~ /real(?:\\p\d{2}_ts)?\d{2}\\financial\\vanuatu_std-hr_usd/);

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

    my $to_client = BOM::User::Client->get_client_instance($to_loginid, 'write');

    return _mt5_validate_and_get_amount($client, $to_loginid, $fm_mt5, $amount, $error_code, $currency_check)->then(
        sub {
            my ($response) = @_;
            return Future->done($response) if (ref $response eq 'HASH' and $response->{error});
            my $account_type = $response->{account_type};

            my $fees                      = $response->{fees};
            my $fees_currency             = $response->{fees_currency};
            my $fees_in_client_currency   = $response->{fees_in_client_currency};
            my $mt5_amount                = $response->{mt5_amount};
            my $fees_percent              = $response->{fees_percent};
            my $mt5_currency_code         = $response->{mt5_currency_code};
            my $fee_calculated_by_percent = $response->{calculated_fee};
            my $min_fee                   = $response->{min_fee};

            my $mt5_login_id = $fm_mt5 =~ s/${\BOM::User->MT5_REGEX}//r;
            my $comment      = "Transfer from MT5 account $account_type $mt5_login_id to $to_loginid.";

            # transaction metadata for statement remarks
            my %txn_details = (
                mt5_account               => $mt5_login_id,
                fees                      => $fees,
                fees_currency             => $fees_currency,
                fees_percent              => $fees_percent,
                min_fee                   => $min_fee,
                fee_calculated_by_percent => $fee_calculated_by_percent
            );

            my $additional_comment = BOM::RPC::v3::Cashier::get_transfer_fee_remark(%txn_details);
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
                            amount      => $mt5_amount,
                            currency    => $to_client->currency,
                            staff       => $to_loginid,
                            remark      => $comment,
                            fees        => $fees_in_client_currency,
                            source      => $source,
                            txn_details => \%txn_details,
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

                        _store_transaction_redis({
                                loginid       => $to_loginid,
                                mt5_id        => $fm_mt5,
                                action        => 'withdraw',
                                amount_in_USD => $amount,
                            }) if ($mt5_group =~ /real(?:\\p\d{2}_ts)?\d{2}\\financial\\vanuatu_std-hr_usd/);

                        return Future->done({
                            status                => 1,
                            binary_transaction_id => $txn->transaction_id
                        });
                    } catch ($e) {
                        my $error = BOM::Transaction->format_error(err => $e);
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

=head2 _get_ib_affiliate_id_from_token

    _get_ib_affiliate_id_from_token($token);

Get IB's affiliate ID based on MyAffiliate token

=over 4

=item * C<$token> string that contains a valid MyAffiliate token

=back

Returns a C<$ib_affiliate_id> an integer representing MyAffiliate ID if it could find and link it to an IB, otherwise returns 0

=cut

sub _get_ib_affiliate_id_from_token {
    my ($token) = @_;

    my $ib_affiliate_id;

    my $aff = WebService::MyAffiliates->new(
        user    => BOM::Config::third_party()->{myaffiliates}->{user},
        pass    => BOM::Config::third_party()->{myaffiliates}->{pass},
        host    => BOM::Config::third_party()->{myaffiliates}->{host},
        timeout => 10
        )
        or do {
        stats_inc('myaffiliates.mt5.failure.connect', 1);
        $log->warnf("Unable to connect to MyAffiliate to parse token %s", $token);
        return 0;
        };

    my $myaffiliate_id = $aff->get_affiliate_id_from_token($token) or do {
        stats_inc('myaffiliates.mt5.failure.get_aff_id', 1);
        $log->warnf("Unable to parse MyAffiliate token %s", $token);
        return 0;
    };

    if ($myaffiliate_id !~ /^\d+$/) {
        $log->warnf("Unable to map token %s to an affiliate (%s)", $token, $myaffiliate_id);
        return $ib_affiliate_id;
    }

    my $affiliate_user = $aff->get_user($myaffiliate_id) or do {
        stats_inc('myaffiliates.mt5.failure.get_aff_id', 1);
        $log->warnf("Unable to get MyAffiliate user %s from token %s", $myaffiliate_id, $token);
        return 0;
    };

    if (ref $affiliate_user->{USER_VARIABLES}{VARIABLE} ne 'ARRAY') {
        stats_inc('myaffiliates.mt5.failure.get_aff_user_variable', 1);
        $log->warnf("User variable is not defined for %s from token %s", $myaffiliate_id, $token);
        return 0;
    }

    try {
        my @mt5_custom_var =
            map { $_->{VALUE} =~ s/\s//rg; } grep { $_->{NAME} =~ s/\s//rg eq 'mt5_account' } $affiliate_user->{USER_VARIABLES}{VARIABLE}->@*;
        $ib_affiliate_id = $myaffiliate_id if $mt5_custom_var[0];
    } catch ($e) {
        $log->warnf("Unable to process affiliate %s custom variables (%s)", $myaffiliate_id, $e);
    }

    return $ib_affiliate_id;
}

=head2 _get_mt5_agent_account_id

    _get_mt5_agent_account_id({account_type => 'real', ...});

Retrieve agent's MT5 account ID on the target server

=over 4

=item * C<$params>

hashref with the following keys

=item * C<$user>

with the value of L<BOM::User> instance

=item * C<$account_type>

with the value of demo/real

=item * C<$country>

with value of country 2 characters code, e.g. ID

=item * C<$affiliate_id>

an integer representing MyAffiliate id as the output of _get_ib_affiliate_id_from_token

=item * C<$market>

market type such financial/synthetic

=back

Return C<$agent_id> an integer representing agent's MT5 account ID if it could find a matching data and 0 otherwise

=cut

sub _get_mt5_agent_account_id {
    my $args = shift;

    my ($user, $affiliate_id, $server) =
        @{$args}{qw(user affiliate_id server)};

    my ($agent_id) = $user->dbic->run(
        fixup => sub {
            $_->selectrow_array(q{SELECT * FROM mt5.get_agent_id(?, ?)}, undef, $affiliate_id, $server);
        });

    if (not $agent_id) {
        stats_inc('myaffiliates.mt5.failure.no_info', 1);
        return 0;
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

    return create_error_future('PermissionDenied', {message => 'Both accounts should belong to the authorized client.'})
        unless _check_logins($authorized_client, \@loginids_list);

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

            my $mt5_group    = $setting->{group};
            my $mt5_lc       = _fetch_mt5_lc($setting);
            my $account_type = _is_account_demo($mt5_group) ? 'demo' : 'real';

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
                return create_error_future('FinancialAssessmentRequired');
            }

            return create_error_future($setting->{status}->{withdrawal_locked}->{error}, {override_code => $error_code})
                if ($action eq 'withdrawal' and $setting->{status}->{withdrawal_locked});

            my $mt5_currency = $setting->{currency};
            return create_error_future('CurrencyConflict', {override_code => $error_code})
                if $currency_check && $currency_check ne $mt5_currency;

            # Check if it's called for virtual top up
            # If yes, then no need to validate client
            if ($account_type eq 'demo' and $action eq 'deposit' and not $loginid) {
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
                $client = BOM::User::Client->get_client_instance($loginid, 'replica');

            } catch {
                log_exception();
                return create_error_future(
                    'InvalidLoginid',
                    {
                        override_code => $error_code,
                        params        => $loginid
                    });
            }

            # Transfer between real and demo accounts is not permitted
            return create_error_future('AccountTypesMismatch') if $client->is_virtual xor ($account_type eq 'demo');
            # Transfer between virtual trading and virtual mt5 is not permitted
            return create_error_future('InvalidVirtualAccount') if $client->is_virtual and not $client->is_wallet;

            # Validate the binary client
            my ($err, $params) = _validate_client($client, $mt5_lc);
            return create_error_future(
                $err,
                {
                    override_code => $error_code,
                    params        => $params
                }) if $err;

            # Don't allow a virtual token/oauth to process a real account.
            return create_error_future('PermissionDenied',
                {message => localize('You cannot transfer between real accounts because the authorized client is virtual.')})
                if $authorized_client->is_virtual and not $client->is_virtual;

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
                and $mt5_group =~ /(?:labuan|vanuatu|bvi)/)
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

                    } catch ($e) {
                        log_exception();
                        # usually we get here when convert_currency() fails to find a rate within $rate_expiry, $mt5_amount is too low, or no transfer fee are defined (invalid currency pair).
                        $err        = $e;
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
                    } catch ($e) {
                        log_exception();
                        # same as previous catch
                        $err = $e;
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

            unless ($client->is_virtual and _is_account_demo($mt5_group)) {
                my $rule_engine = BOM::Rules::Engine->new(client => $client);
                my $validation  = BOM::Platform::Client::CashierValidation::validate(
                    loginid           => $loginid,
                    action            => $action_counterpart,
                    is_internal       => 0,
                    underlying_action => ($action eq 'deposit' ? 'mt5_transfer' : 'mt5_withdraw'),
                    rule_engine       => $rule_engine
                );

                return create_error_future(
                    $error_code,
                    {
                        message       => $validation->{error}{message_to_client},
                        original_code => $validation->{error}{code}}) if exists $validation->{error};
            }

            return Future->done({
                mt5_amount              => $mt5_amount,
                fees                    => $fees,
                fees_currency           => $source_currency,
                fees_percent            => $fees_percent,
                fees_in_client_currency => $fees_in_client_currency,
                mt5_currency_code       => $mt5_currency,
                min_fee                 => $min_fee,
                calculated_fee          => $fee_calculated_by_percent,
                mt5_data                => $setting,
                account_type            => $account_type,
            });
        });
}

sub _fetch_mt5_lc {
    my $settings = shift;

    my $group_params = parse_mt5_group($settings->{group});

    return undef unless $group_params->{landing_company_short};

    my $landing_company = LandingCompany::Registry->by_name($group_params->{landing_company_short});

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

    # if it's a legitimate virtual transfer, skip the rest of validations
    return undef if $client_obj->is_virtual;

    my $lc = $client_obj->landing_company->short;

    # Landing companies listed below are an exception for this check as
    # they have mutual agreement and it is allowed to transfer funds
    # through gaming/financial MT5 accounts:
    # - transfers between maltainvest and malta
    # - svg, vanuatu, and labuan

    my $mt5_lc_short = $mt5_lc->short;

    unless (($lc eq 'svg' and ($mt5_lc_short eq 'vanuatu' or $mt5_lc_short eq 'labuan' or $mt5_lc_short eq 'bvi'))
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

    my $first = first {
        $_ =~ /^real\\${similar_company}_financial(?:_Bbook)?$/
            || $_ =~ /^real(?:\\p\d{2}_ts)?\d{2}\\financial\\${similar_company}_std(?:-hr)?_usd$/

    }
    keys %$existing_group;

    return $first;
}

=head2 _get_market_type

Return the market type for the mt5 account details

=cut

sub _get_market_type {
    my ($account_type, $mt5_account_type) = @_;

    my $market_type = '';
    if ($account_type eq 'demo') {
        # if $mt5_account_type is undefined, it maps to $market_type=synthetic, else $market_type=financial
        $market_type = $mt5_account_type ? 'financial' : 'synthetic';
    } else {
        $market_type = $account_type eq 'gaming' ? 'synthetic' : 'financial';
    }

    return $market_type;
}

1;
