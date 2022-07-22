package BOM::User;

use strict;
use warnings;
no indirect;

use feature 'state';
use Syntax::Keyword::Try;
use Date::Utility;
use Format::Util::Numbers qw(formatnumber);
use List::Util qw(first any all minstr);
use Scalar::Util qw(blessed looks_like_number);
use Carp qw(croak carp);
use Log::Any qw($log);
use JSON::MaybeXS qw(encode_json decode_json);

use BOM::MT5::User::Async;
use BOM::Database::UserDB;
use BOM::Database::Model::UserConnect;
use BOM::User::Password;
use BOM::User::AuditLog;
use BOM::User::Static;
use BOM::User::Utility;
use BOM::User::Client;
use BOM::User::Wallet;
use BOM::User::Affiliate;
use BOM::User::Onfido;
use BOM::User::RiskScreen;
use BOM::User::SocialResponsibility;
use BOM::TradingPlatform;
use BOM::Config::Runtime;
use ExchangeRates::CurrencyConverter qw(in_usd);
use BOM::Platform::Redis;
use LandingCompany::Registry;
use BOM::Platform::Context qw(request);
use Exporter qw( import );
our @EXPORT_OK = qw( is_payment_agents_suspended_in_country );

=head1 NAME

BOM::User

=cut

# Backoffice Application Id used in some login cases
use constant BACKOFFICE_APP_ID => 4;
# Redis key prefix for client's previous login attempts
use constant CLIENT_LOGIN_HISTORY_KEY_PREFIX => "CLIENT_LOGIN_HISTORY::";
# Redis key prefix for counting daily user transfers
use constant DAILY_TRANSFER_COUNT_KEY_PREFIX => "USER_TRANSFERS_DAILY::";

sub dbic {
    my (undef, %params) = @_;
    #not caching this as the handle is cached at a lower level and
    #if it does cache a bad handle here it will not recover.
    return BOM::Database::UserDB::rose_db(%params)->dbic;
}

=head2 create

Create new record in table users.binary_user

=cut

my @fields =
    qw(id email password email_verified utm_source utm_medium utm_campaign app_id email_consent gclid_url has_social_signup secret_key is_totp_enabled signup_device date_first_contact utm_data preferred_language trading_password dx_trading_password);

# generate attribute accessor
for my $k (@fields) {
    no strict 'refs';
    *{__PACKAGE__ . '::' . $k} = sub { shift->{$k} }
        unless __PACKAGE__->can($k);
}

use constant {
    MT5_REGEX            => qr/^MT[DR]?(?=\d+$)/,
    MT5_REAL_REGEX       => qr/^MT[R]?(?=\d+$)/,
    MT5_DEMO_REGEX       => qr/^MTD(?=\d+$)/,
    VIRTUAL_REGEX        => qr/^VR[TC|CH]/,
    VIRTUAL_WALLET_REGEX => qr/^VRDW\d+/,
    DXTRADE_REGEX        => qr/^DX[DR]\d{4,}/,
    DXTRADE_REAL_REGEX   => qr/^DXR(?=\d+$)/,
    DXTRADE_DEMO_REGEX   => qr/^DXD(?=\d+$)/,
};

sub create {
    my ($class, %args) = @_;
    croak "email and password are mandatory" unless (exists($args{email}) && exists($args{password}));

    if ($args{utm_data}) {
        $args{utm_data} = keys %{$args{utm_data}} ? encode_json($args{utm_data}) : undef;
    }

    my @new_values = @args{@fields};
    shift @new_values;    #remove id value
    my $placeholders = join ",", ('?') x @new_values;

    my $sql    = "select * from users.create_user($placeholders)";
    my $result = $class->dbic->run(
        fixup => sub {
            $_->selectrow_hashref($sql, undef, @new_values);
        });
    return bless $result, $class;
}

=head2 new

Load a user record from db. There must be a key id, email or loginid

=cut

sub new {
    my ($class, %args) = @_;
    my $k = first { exists $args{$_} } qw(id email loginid);
    croak "no email nor id or loginid" unless $k;

    my $v    = $args{$k};
    my $self = $class->dbic->run(
        fixup => sub {
            $_->selectrow_hashref("select * from users.get_user_by_$k(?)", undef, $v);
        });

    return undef unless $self;
    return bless $self, $class;
}

sub add_client {
    my ($self, $client) = @_;
    croak('need a client') unless $client;
    $self->add_loginid($client->loginid);
    return $self;
}

sub add_loginid {
    my ($self, $loginid, $platform, $account_type, $currency, $attributes) = @_;
    croak('need a loginid') unless $loginid;
    $attributes = encode_json($attributes) if $attributes;
    my ($result) = $self->dbic->run(
        fixup => sub {
            return $_->selectrow_array('select users.add_loginid(?, ?, ?, ?, ?, ?)',
                undef, $self->{id}, $loginid, $platform, $account_type, $currency, $attributes);
        });
    delete $self->{loginid_details} if $result;
    return $self;
}

=head2 loginid_details

Get all loginids linked to the user with all fields.

Returns hashref.

=cut

sub loginid_details {
    my $self = shift;
    return $self->{loginid_details} if $self->{loginid_details};
    my $loginids = $self->dbic->run(
        fixup => sub {
            return $_->selectall_arrayref(
                'select loginid, platform, account_type, currency, attributes, status from users.get_loginids(?)',
                {Slice => {}},
                $self->{id});
        });
    $self->{loginid_details} = {};
    for my $login (@$loginids) {
        $login->{attributes} = decode_json($login->{attributes} // '{}');
        $self->{loginid_details}{$login->{loginid}} = $login;
    }
    return $self->{loginid_details};
}

=head2 loginids

Gets loginids linked to the user, sorted.

Returns array.

=cut

sub loginids {
    my $self = shift;
    return (sort keys $self->loginid_details->%*);
}

sub login_attributes {

}

=head2 create_client

Takes one or more named parameters:

=over 4

=item * C<landing_company> - e.g. `svg`

=back

=cut

sub create_client {
    my ($self, %args) = @_;
    $args{binary_user_id} = $self->{id};
    my $client = BOM::User::Client->register_and_return_new_client(\%args);
    $self->add_client($client);
    return $client;
}

=head2 create_wallet

Creates a new wallet

=over 4

=item * C<args> new wallet details

=back

=cut

sub create_wallet {
    my ($self, %args) = @_;
    $args{binary_user_id} = $self->{id};

    my $lock_name = 'WALLET::CREATION' . $self->{id};
    die "User $self->{id} is trying to create 2 wallets at the same time" unless BOM::Platform::Redis::acquire_lock($lock_name, 30);
    try {
        #Check for dublicates
        for my $client ($self->clients(include_disabled => 0)) {
            next unless $client->is_wallet;
            next unless ($client->payment_method         // '') eq ($args{payment_method} // '');
            next unless ($client->account->currency_code // '') eq ($args{currency}       // '');

            die +{error => 'DuplicateWallet'};
        }

        my $currency_code = delete $args{currency};
        my $wallet        = BOM::User::Wallet->register_and_return_new_client(\%args);
        $wallet->set_default_account($currency_code);

        # in current back-end perspective wallet is a client
        $self->add_client($wallet);

        return $wallet;
    } finally {
        BOM::Platform::Redis::release_lock($lock_name);
    }
}

=head2 create_affiliate

Creates a new affiliate account

=over 4

=item * C<args> new affiliate details

=back

=cut

sub create_affiliate {
    my ($self, %args) = @_;
    $args{binary_user_id} = $self->{id};
    my $client = BOM::User::Affiliate->register_and_return_new_client(\%args);
    $self->add_client($client);
    return $client;
}

=head2 login

Check user credentials.
Returns hashref, {success => 1} if successfully authenticated user or {error => 'failed reason'} otherwise.

=cut

sub login {
    my ($self, %args) = @_;

    my $password               = $args{password}               || die "requires password argument";
    my $environment            = $args{environment}            || '';
    my $is_social_login        = $args{is_social_login}        || 0;
    my $is_refresh_token_login = $args{is_refresh_token_login} || 0;
    my $app_id                 = $args{app_id}                 || undef;

    use constant {
        MAX_FAIL_TIMES   => 5,
        ATTEMPT_INTERVAL => '5 minutes'
    };
    my @clients;
    my $error;
    my $too_many_attempts = $self->dbic->run(
        fixup => sub {
            $_->selectrow_arrayref('select users.too_many_login_attempts(?::BIGINT, ?::SMALLINT, ?::INTERVAL)',
                undef, $self->{id}, MAX_FAIL_TIMES, ATTEMPT_INTERVAL)->[0];
        });

    if ($too_many_attempts) {
        $error = 'LoginTooManyAttempts';
    } elsif (!$is_social_login && !$is_refresh_token_login && !BOM::User::Password::checkpw($password, $self->{password})) {
        $error = 'INVALID_CREDENTIALS';
    } elsif (!(@clients = $self->clients)) {
        $error = $self->clients(include_self_closed => 1) ? 'AccountSelfClosed' : 'AccountUnavailable';
    }

    $self->after_login($error, $environment, $app_id, @clients);

    state $error_mapping = BOM::User::Static::get_error_mapping();

    return {
        error      => $error_mapping->{$error},
        error_code => $error
    } if $error;

    return {
        success => 1,
    };
}

=head2 after_login

Finishes the processing of a login attempt by:

1- Saving the result in login history and redis

2- setting gamstop self-exclusion if applicable

It takes following args:

=over 4

=item * C<$error> - The error code if there's any; B<undef> or 0 if login was successful.

=item * C<$environment> - The runtime environment of the requesting web client represented as a string.

=item * C<$app_id> - The application id used in websocket connection.

=item * C<@clients> - An array consisting of the matched client objects (for successful login only).

=back

=cut

sub after_login {
    my ($self, $error, $environment, $app_id, @clients) = @_;
    my $log_as_failed = ($error // '' eq 'LoginTooManyAttempts') ? 1 : 0;

    state $error_log_msgs = {
        LoginTooManyAttempts => "failed login > " . MAX_FAIL_TIMES . " times",
        INVALID_CREDENTIALS  => 'incorrect email or password',
        AccountUnavailable   => 'Account disabled',
        Success              => 'successful login',
        AccountSelfClosed    => 'Account is self-closed',
    };
    my $result = $error || 'Success';
    BOM::User::AuditLog::log($error_log_msgs->{$result}, $self->{email});

    $self->dbic->run(
        fixup => sub {
            $_->do('select users.record_login_history(?,?,?,?,?)', undef, $self->{id}, $error ? 'f' : 't', $log_as_failed, $environment, $app_id);
        });

    return if $error;

    # store this login attempt in redis
    $self->_save_login_detail_redis($environment);

    my $countries_list = request()->brand->countries_instance->countries_list;
    my $gamstop_client = first {
        my $client = $_;
        any { $client->landing_company->short eq $_ } ($countries_list->{$client->residence}->{gamstop_company} // [])->@*
    }
    @clients;

    BOM::User::Utility::set_gamstop_self_exclusion($gamstop_client) if $gamstop_client;

    return undef;
}

=head2 clients

Gets corresponding client objects in loginid order but with real and enabled accounts up first.

By default it returns only active (enabled) clients, but the result may include other clients base on the following named args:

=over 4

=item * C<include_disabled> - disabled accounts will be included in the result if this arg is true.

=item * C<include_duplicated> - if called with include_duplicated=>1, the result will include duplicate  accounts; otherwise not.

=item * C<include_self_closed> - Self-closed clients will be included in the result if this arg is true.

=item * C<db_operation> - defaults to write.

=back

Returns client objects array

=cut

sub clients {
    my ($self, %args) = @_;

    my @clients = @{$self->get_clients_in_sorted_order(%args)};

    # return all clients (disabled and self-closed clients included)
    return @clients if $args{include_disabled};

    #return self-closed or active clients only
    return grep { $_->status->closed or not $_->status->disabled } @clients if $args{include_self_closed};

    # return just active clients
    return grep { not $_->status->disabled } @clients;
}

=head2 clients_for_landing_company

get clients given special landing company short name.
    $user->clients_for_landing_company('svg');

%args can contain:

=over 4

=item * C<db_operation> - defaults to write.

=back

=cut

sub clients_for_landing_company {
    my ($self, $lc_short, %args) = @_;

    die 'need landing_company' unless $lc_short;

    my @login_ids = grep { LandingCompany::Registry->check_broker_from_loginid($_) } $self->bom_loginids;

    return map { BOM::User::Client->get_client_instance($_, $args{db_operation} // 'write') }
        grep { LandingCompany::Registry->by_loginid($_)->short eq $lc_short } @login_ids;
}

=head2 bom_loginid_details

get client non-mt5 login id details

=cut

sub bom_loginid_details {
    my $self = shift;

    my %hash = map { $_ => {loginid => $_, broker_code => ($_ =~ /(^[a-zA-Z]+)/)} } $self->bom_loginids;
    return \%hash;
}

=head2 bom_loginids

get client non-mt5 login ids

=cut

sub bom_loginids {
    my $self = shift;
    return grep { $_ !~ MT5_REGEX && $_ !~ DXTRADE_REGEX } $self->loginids;
}

=head2 bom_real_loginids

get non-mt5 real login ids

=cut

sub bom_real_loginids {
    my $self = shift;
    return grep { $_ !~ MT5_REGEX && $_ !~ DXTRADE_REGEX && $_ !~ VIRTUAL_REGEX } $self->loginids;
}

=head2 bom_virtual_loginid

get non-mt5 virtual login id

=cut

sub bom_virtual_loginid {
    my $self = shift;
    return first { $_ =~ VIRTUAL_REGEX } $self->loginids;
}

=head2 bom_virtual_wallet_loginid

get virtual wallet login ids

=cut

sub bom_virtual_wallet_loginid {
    my $self = shift;
    return grep { $_ =~ VIRTUAL_WALLET_REGEX } $self->loginids;
}

=head2 mt5_logins

get mt5 loginids for the user

=over 4

=item * C<self> - self user object

=item * C<filter> - regex to filter out groups

=back

Returns a list of mt5 loginids

=cut

sub mt5_logins {
    my $self = shift;

    my $filter = shift // 'real|demo';

    my @mt5_logins = sort keys %{$self->mt5_logins_with_group($filter)};

    return @mt5_logins;
}

=head2 mt5_logins_with_group

get mt5 logins with group for the user

=over 4

=item * C<self> - self user object

=item * C<filter> - regex to filter out groups

=back

Returns a hashref of form { login => group }

=cut

sub mt5_logins_with_group {
    my $self = shift;

    my $filter                = shift // 'real|demo';
    my $mt5_logins_with_group = {};

    for my $login (sort $self->get_mt5_loginids()) {
        my $group = BOM::MT5::User::Async::get_user($login)->else(sub { Future->done({}) })->get->{group} // '';
        $mt5_logins_with_group->{$login} = $group if (not $filter or $group =~ /^$filter/);
    }

    return $mt5_logins_with_group;
}

=head2 dxtrade_loginids

get dxtrade loginids for the user

=cut

sub dxtrade_loginids {
    my ($self, $type) = @_;

    my @loginids = sort $self->get_trading_platform_loginids('dxtrader', $type);
    return @loginids;
}

sub get_last_successful_login_history {
    my $self = shift;

    return $self->dbic->run(fixup => sub { $_->selectrow_hashref('SELECT * FROM users.get_last_successful_login_history(?)', undef, $self->{id}) });
}

=head2 has_mt5_regulated_account

Check if user has any mt5 regulated account - currently its only Labuan

=cut

sub has_mt5_regulated_account {
    my $self = shift;

    # We want to check the real mt5 accounts, so we filter out MTD, then reverse sort,
    # that will move MTR first, and latest created id first
    my @all_mt5_loginids = $self->get_mt5_loginids(type_of_account => 'real');
    return 0 unless @all_mt5_loginids;

    my @loginids = reverse sort @all_mt5_loginids;
    return Future->wait_all(map { BOM::MT5::User::Async::get_user($_) } @loginids)->then(
        sub {
            # TODO (JB): to remove old group mapping once all accounts are moved to new group
            return Future->done(1) if any {
                $_->is_done
                    && ($_->result->{group} =~ /^(?!demo)[a-z]+\\(?!svg)[a-z]+(?:_financial)/
                    || $_->result->{group} =~ /^real(\\p01_ts)?(?:01|02|03|04)\\financial\\(?!svg)/)
            }
            @_;
            return Future->done(0);
        })->get;
}

=head2 get_clients_in_sorted_order

Return an ARRAY reference that is a list of clients in following order

- real enabled accounts (fiat first, then crypto)
- virtual accounts
- self excluded accounts
- disabled accounts

%args can contain:

=over 4

=item * C<db_operation> - defaults to write.

=back

=cut

sub get_clients_in_sorted_order {
    my ($self, %args) = @_;
    my $account_lists    = $self->accounts_by_category([$self->bom_loginids], %args);
    my @allowed_statuses = qw(enabled virtual self_excluded disabled);
    push @allowed_statuses, 'duplicated' if ($args{include_duplicated});

    return [map { @$_ } @{$account_lists}{@allowed_statuses}];
}

=head2 accounts_by_category

Given the loginid list, return the accounts grouped by the category in a HASH reference.
The categories are:

- real enabled accounts (fiat first, then crypto)
- virtual accounts
- self excluded accounts
- disabled accounts
- duplicated accounts

%args can contain:

=over 4

=item * C<db_operation> - defaults to write.

=back

=cut

sub accounts_by_category {
    my ($self, $loginid_list, %args) = @_;

    my (@enabled_accounts_fiat, @enabled_accounts_crypto, @virtual_accounts, @self_excluded_accounts, @disabled_accounts, @duplicated_accounts);
    foreach my $loginid (sort @$loginid_list) {
        # deleted broker code/not existing broker code then skip it to avoid couldn't init_db issue
        unless (LandingCompany::Registry->check_broker_from_loginid($loginid)) {
            $log->warnf("Invalid login id $loginid");
            next;
        }

        my $cl = BOM::User::Client->get_client_instance($loginid, $args{db_operation} // 'write');
        next unless $cl;

        next if ($cl->status->is_login_disallowed and not $args{include_duplicated});

        # we store the first suitable client to _disabled_real_client/_self_excluded_client/_virtual_client/_first_enabled_real_client.
        # which will be used in get_default_client
        if ($cl->status->disabled) {
            push @disabled_accounts, $cl;
            next;
        }

        if ($cl->get_self_exclusion_until_date) {
            push @self_excluded_accounts, $cl;
            next;
        }

        if ($cl->is_virtual) {
            push @virtual_accounts, $cl;
            next;
        }

        if ($cl->status->duplicate_account) {
            push @duplicated_accounts, $cl;
            next;
        }

        push @{
            BOM::Config::CurrencyConfig::is_valid_crypto_currency($cl->currency)
            ? \@enabled_accounts_crypto
            : \@enabled_accounts_fiat
            },
            $cl;
    }

    my @enabled_accounts = (@enabled_accounts_fiat, @enabled_accounts_crypto);

    return {
        enabled       => \@enabled_accounts,
        virtual       => \@virtual_accounts,
        self_excluded => \@self_excluded_accounts,
        disabled      => \@disabled_accounts,
        duplicated    => \@duplicated_accounts
    };
}

=head2 get_default_client

Returns default client for particular user
Act as replacement for using "$siblings[0]" or "$clients[0]"

=over 4

=item * C<include_disabled> - include disabled clients

=item * C<include_duplicated> - include duplicated clients

=back

Returns An array of L<BOM::User::Client> s

=cut

sub get_default_client {
    my ($self, %args) = @_;

    return $self->{_default_client_include_disabled} if exists($self->{_default_client_include_disabled}) && $args{include_disabled};
    return $self->{_default_client_without_disabled} if exists($self->{_default_client_without_disabled}) && !$args{include_disabled};

    my $client_lists = $self->accounts_by_category([$self->bom_loginids], %args);
    my %tmp;
    foreach my $k (keys %$client_lists) {
        $tmp{$k} = pop(@{$client_lists->{$k}});
    }
    $self->{_default_client_include_disabled} = $tmp{enabled} // $tmp{disabled} // $tmp{virtual} // $tmp{self_excluded} // $tmp{duplicated};
    $self->{_default_client_without_disabled} = $tmp{enabled} // $tmp{virtual}  // $tmp{self_excluded};
    return $self->{_default_client_include_disabled} if $args{include_disabled};
    return $self->{_default_client_without_disabled};
}

sub failed_login {
    my $self = shift;
    return $self->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('select * from users.get_failed_login(?)', undef, $self->{id});
        });
}

sub login_history {
    my ($self, %args) = @_;
    $args{order} //= 'desc';
    my $limit = looks_like_number($args{limit}) ? "limit $args{limit}" : '';
    my $sql   = "select * from users.get_login_history(?,?,?) $limit";
    return $self->dbic(operation => 'replica')->run(
        fixup => sub {
            $_->selectall_arrayref($sql, {Slice => {}}, $self->{id}, $args{order}, $args{show_impersonate_records} // 0);
        });
}

sub add_login_history {
    my ($self, %args) = @_;
    $args{binary_user_id} = $self->{id};

    if ($args{app_id} == BACKOFFICE_APP_ID) {

        # Key format: binary user id, epoch
        my $key   = $self->{id} . '-' . $args{token};
        my $redis = BOM::Config::Redis::redis_replicated_write();

        # If the key exists, there is no need to do anything else
        # Otherwise:
        # - Store the key,
        # - or if it is a logout session, remove the key
        if ($args{action} eq 'login') {
            return undef unless $redis->setnx($key, 1);
        } else {
            $redis->del($key);
        }
    } elsif ($args{successful} && $args{action} eq 'login') {
        # register successful attempt in redis to be compared later
        $self->_save_login_detail_redis($args{environment});
    }

    my @history_fields = qw(binary_user_id action environment successful ip country app_id);
    my @new_values     = @args{@history_fields};

    my $placeholders = join ",", ('?') x @new_values;
    my $sql          = "select * from users.add_login_history($placeholders)";
    $self->dbic->run(
        fixup => sub {
            $_->do($sql, undef, @new_values);
        });
    return $self;
}

################################################################################
# update_* functions
# Style: if the function can update several fields, then it will be named as update_*_fields
# and the args will be a hash
# if that function can only update one field, then it will be named as update_* directly,
# and the arg will be that field directly
################################################################################
sub update_email_fields {
    my ($self, %args) = @_;
    $args{email} = lc $args{email} if $args{email};
    my ($email, $email_consent, $email_verified) = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array('select * from users.update_email_fields(?, ?, ?, ?)',
                undef, $self->{id}, $args{email}, $args{email_consent}, $args{email_verified});
        });
    $self->{email}          = $email;
    $self->{email_consent}  = $email_consent;
    $self->{email_verified} = $email_verified;
    return $self;
}

sub update_totp_fields {
    my ($self, %args) = @_;

    my $user_is_totp_enabled = $self->is_totp_enabled;

    # if 2FA is enabled, we won't update the secret key
    if ($args{secret_key} && $user_is_totp_enabled && ($args{is_totp_enabled} // 1)) {
        return;
    }

    my ($new_is_totp_enabled, $secret_key) = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array('select * from users.update_totp_fields(?, ?, ?)', undef, $self->{id}, $args{is_totp_enabled}, $args{secret_key});
        });
    $self->{is_totp_enabled} = $new_is_totp_enabled;
    $self->{secret_key}      = $secret_key;

    # revoke tokens if 2FA is updated
    if ($user_is_totp_enabled xor $new_is_totp_enabled) {
        my $oauth = BOM::Database::Model::OAuth->new;
        $oauth->revoke_tokens_by_loginid($_->loginid) for ($self->clients);
        $oauth->revoke_refresh_tokens_by_user_id($self->id);
    }

    return $self;
}

sub update_password {
    my ($self, $password) = @_;
    $self->{password} = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array('select * from users.update_password(?, ?)', undef, $self->{id}, $password);
        });
    return $self;
}

sub update_has_social_signup {
    my ($self, $has_social_signup) = @_;
    $self->{has_social_signup} = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array('select * from users.update_has_social_signup(?, ?)', undef, $self->{id}, $has_social_signup);
        });
    return $self;
}

=head2 is_payment_agents_suspended_in_country

 	my $suspended = is_payment_agents_suspended_in_country('ru');

 Tells if payment agent transfer is suspended in the input country.

=cut

sub is_payment_agents_suspended_in_country {
    my $country = shift;
    return 0 unless $country;
    my $suspended_countries = BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries;
    return any { $_ eq $country } @$suspended_countries;
}

=head2 filter_active_ids

my $loginids = Reference list of all MT5 accounts associated with current client account;

Filter the list of MT5 accounts to only get active accounts.

Active account contains status of 'undef'.
Other possible status includes:
    'disabled',
    'migrated_single_email',
    'duplicate_account',
    'archived'

=cut

sub filter_active_ids {
    my ($self, $loginids) = @_;
    # Since there are no plans to add "active" to status of active account in DB, current active accounts
    # contain status of 'undef'.
    return [grep { not defined($self->{loginid_details}{$_}{status}) } @$loginids];
}

=head2 get_mt5_loginids

my $mt5_loginids = $self->get_mt5_loginids(); # all mt5 loginids that are active accounts.
my $mt5_real = $self->get_mt5_loginids(type_of_account => 'real'); real mt5 loginids that are active accounts.
my $mt5_loginids = $self->get_mt5_loginids(type_of_account => 'all', include_all_status => 1); # all mt5 loginids regardless of its status.

args type_of_account; Can be value of ['all', 'demo', 'real']. Indicate which 'type' of server to get account from.
     include_all_status => 0; Get only active accounts (status = undef).
     include_all_status => 1; Get all accounts regardless of its status.

=cut

sub get_mt5_loginids {
    my ($self, %args) = @_;
    $args{type_of_account}    //= 'all';
    $args{include_all_status} //= 0;

    my $type = 'real';
    $type = 'demo' if $args{type_of_account} eq 'demo';
    $type = 'all'  if $args{type_of_account} eq 'all';

    my @loginids = sort $self->get_trading_platform_loginids('mt5', $type // 'all');
    @loginids = @{$self->filter_active_ids(\@loginids)} unless $args{include_all_status};

    return @loginids;
}

=head2 get_loginid_for_mt5_id

Method returns mt5 login with prefix for mt5 numeric user id.

=cut

sub get_loginid_for_mt5_id {
    my ($self, $mt5_id) = @_;

    my @logins = grep { $mt5_id eq s/${\MT5_REGEX}//r } $self->get_mt5_loginids;

    return undef unless @logins;

    return $logins[0] if @logins == 1;

    die "User " . $self->id . " has several mt5 logins with same id: " . join q{, } => @logins;
}

=head2 is_closed

Returns true or false if a user has been disabled, for example by the account_closure API call.
In our system, this means all sub accounts have disabled status.

=cut

sub is_closed {
    my $self = shift;
    return all { $_->status->disabled } $self->clients;
}

sub _save_login_detail_redis {
    my ($self, $environment) = @_;

    my $key        = CLIENT_LOGIN_HISTORY_KEY_PREFIX . $self->id;
    my $entry      = BOM::User::Utility::login_details_identifier($environment);
    my $entry_time = time;

    my $auth_redis = BOM::Config::Redis::redis_auth_write();
    try {
        $auth_redis->hset($key, $entry, $entry_time);
    } catch {
        $log->warnf("Failed to store user login entry in redis, error: %s", shift);
    }
}

sub logged_in_before_from_same_location {
    my ($self, $new_env) = @_;

    my $key   = CLIENT_LOGIN_HISTORY_KEY_PREFIX . $self->id;
    my $entry = BOM::User::Utility::login_details_identifier($new_env);

    my $auth_redis    = BOM::Config::Redis::redis_auth();
    my $attempt_known = undef;
    try {
        $attempt_known = $auth_redis->hget($key, $entry);
        return $attempt_known if $attempt_known;
        # for backward compatibility with users who never changed their login.
        my $last_attempt_in_db = $self->get_last_successful_login_history();
        return 1 unless $last_attempt_in_db;

        my $last_attempt_entry = BOM::User::Utility::login_details_identifier($last_attempt_in_db->{environment});
        return 1 if $last_attempt_entry eq $entry;
    } catch {
        $log->warnf("Failed to get user login entry from redis, error: %s", shift);
    }

    return $attempt_known;
}

=head2 daily_transfer_incr

Increments number of transfers per day in redis.

=cut

sub daily_transfer_incr {
    my ($self, $type) = @_;
    $type //= 'internal';

    my $redis     = BOM::Config::Redis::redis_replicated_write();
    my $redis_key = DAILY_TRANSFER_COUNT_KEY_PREFIX . $type . '_' . $self->id;
    my $expiry    = 86400 - Date::Utility->new->seconds_after_midnight;

    $redis->multi;
    $redis->incr($redis_key);
    $redis->expire($redis_key, $expiry);
    $redis->exec;

    return;
}

=head2 daily_transfer_count

Gets number of transfers made in the current day.

=cut

sub daily_transfer_count {
    my ($self, $type) = @_;
    $type //= 'internal';

    my $redis     = BOM::Config::Redis::redis_replicated_write();
    my $redis_key = DAILY_TRANSFER_COUNT_KEY_PREFIX . $type . '_' . $self->id;

    return $redis->get($redis_key) // 0;
}

=head2 valid_to_anonymize

Determines if the user is valid to anonymize or not.

Returns 1 if the user is valid to anonymize
Returns 0 otherwise

=cut

sub valid_to_anonymize {
    my $self = shift;

    my $result = BOM::Database::ClientDB->new({
            broker_code => 'FOG',
            operation   => 'collector',
        }
    )->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT users.ck_user_valid_to_anonymize(?)', undef, $self->id);
        });

    my @clients = $self->clients(
        include_disabled   => 1,
        include_duplicated => 1,
    );

    # filter out virtual clients
    # The standard anonymization rules don't apply for clients with no real money accounts. They can be anonymized at any time.
    my $real_clients = first { not $_->is_virtual } @clients;
    $real_clients ? return $result->{ck_user_valid_to_anonymize} : return 1;
}

=head2 get_client_using_replica

Return the BOM::User::Client object that will use the replica database
In case of any issue with the replica it will use the master database.

=over

=item * C<$login_id> client login id

=back

returns a L<BOM::User::Client> or undef if not successful

=cut

sub get_client_using_replica {
    my ($self, $login_id) = @_;
    my $cl;
    my $error;

    try {
        $cl = BOM::User::Client->get_client_instance($login_id, 'replica');
    } catch ($e) {
        $log->warnf("Error getting replica connection: %s", $e);
        $error = $e;
    }

    # try master if replica is down
    $cl = BOM::User::Client->get_client_instance($login_id, 'write') if not $cl or $error;

    return $cl;
}

=head2 total_deposits

get the total value of deposits for this user

=over

=back

total value of all deposits in USD

=cut

sub total_deposits {
    my ($self) = @_;

    my @clients = $self->clients(include_disabled => 0);

    # filter out virtual clients
    @clients = grep { not $_->is_virtual } @clients;

    my $total = 0;
    for my $client (@clients) {
        my $replica_client = $self->get_client_using_replica($client->loginid);
        my $count          = $replica_client->db->dbic->run(
            fixup => sub {
                $_->selectrow_hashref("select payment.get_total_deposit(?);", undef, $client->loginid);
            });
        $total += in_usd($count->{get_total_deposit}, $client->currency) if $count->{get_total_deposit};
    }
    return $total;
}

=head2 total_trades

get the total value of all trades of this user

=over

=back

total value of all trades in USD

=cut

sub total_trades {
    my ($self) = @_;

    my @clients = $self->clients(include_disabled => 0);

    # filter out virtual clients
    @clients = grep { not $_->is_virtual } @clients;

    my $total = 0;
    for my $client (@clients) {
        # Check if client has no currency code
        next unless $client->account;

        my $replica_client = $self->get_client_using_replica($client->loginid);
        my $count          = $replica_client->db->dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT SUM(buy_price) as amount FROM bet.financial_market_bet WHERE account_id = ?;',
                    undef, $client->account->id);
            });
        $total += in_usd($count->{amount}, $client->currency) if $count->{amount};
    }
    return $total;
}

=head2 is_crypto_withdrawal_suspicious

check if the client is suspicious based in the following requirements:

1 - The client has no trade on crypto and fiat
2 - The client has traded on crypto or fiat but the amount he traded is 25% less than the amount he had deposited

=over

=back

return 1 for suspicious client 0 for non suspicious client

=cut

sub is_crypto_withdrawal_suspicious {
    my ($self) = @_;

    my $total_deposits = $self->total_deposits();
    my $total_trades   = $self->total_trades();
    my $percent        = $total_deposits / 4;

    if ($total_trades == 0 || $total_trades < $percent) {
        return 1;
    }

    return 0;
}

=head2 set_tnc_approval

Marks the current terms & conditions version as accepted by user for the current brand.
Updates the timestamp if user has already accepted the version.

=cut

sub set_tnc_approval {
    my $self = shift;

    my $version = $self->current_tnc_version or return;

    return $self->dbic->run(
        fixup => sub {
            $_->do('SELECT users.set_tnc_approval(?, ?, ?)', undef, $self->{id}, $version, request()->brand->name);
        });
}

=head2 latest_tnc_version

Returns the most recent terms & conditions version the user has accepted for the current brand.

=cut

sub latest_tnc_version {
    my $self = shift;

    return $self->dbic->run(
        fixup => sub {
            $_->selectrow_array('SELECT version FROM users.get_tnc_approval(?, ?) LIMIT 1', undef, $self->{id}, request()->brand->name);
        }) // '';
}

=head2 current_tnc_version

Returns the current configured terms & conditions version for the current brand.

=cut

sub current_tnc_version {
    my $self = shift;

    my $tnc_versions = BOM::Config::Runtime->instance->app_config->cgi->terms_conditions_versions;
    my $tnc_config   = decode_json($tnc_versions);
    my $brand_name   = request()->brand->name;
    return $tnc_config->{$brand_name};
}

=head2 setnx_preferred_language

Set preferred language if not exists

=cut

sub setnx_preferred_language {
    my ($self, $lang_code) = @_;

    $self->update_preferred_language($lang_code) if !$self->{preferred_language};
}

=head2 update_preferred_language

Update user's preferred language

Returns 2 char-length language code

=cut

sub update_preferred_language {
    my ($self, $lang_code) = @_;

    my $result = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array('select * from users.update_preferred_language(?, ?)', undef, $self->{id}, uc $lang_code);
        });

    $self->{preferred_language} = $result if $result;

    return $self->{preferred_language};
}

=head2 has_virtual_client

Returns error code if a virtual client or a virtual wallet client already exists, otherwise returns undef

=cut

sub has_virtual_client {
    my ($self, $is_wallet) = @_;
    my $vr_clients = first { $_->is_virtual } $self->clients;    # can be vrtc or vrdw
    my $loginid    = $vr_clients->{loginid};
    if ($loginid) {
        my $client = BOM::User::Client->get_client_instance($loginid);
        return 'duplicate email'        if !$is_wallet && !$client->is_wallet;    # a virtual client already exists
        return 'DuplicateVirtualWallet' if $is_wallet  && $client->is_wallet;     # a virtual wallet client already exists
    }
    return undef;
}

=head2 update_user_password

Update user & clients password for the user.

=over 4

=item * C<$new_password> - new user password

=item * C<$type> - 'reset_password' or 'change_password'

=back

Returns 1 on success

=cut

sub update_user_password {
    my ($self, $new_password, $type) = @_;
    my $is_reset_password = ($type && $type eq 'reset_password') || 0;
    my $log               = '';

    my $hash_pw = BOM::User::Password::hashpw($new_password);
    $self->update_password($hash_pw);

    my $oauth   = BOM::Database::Model::OAuth->new;
    my @clients = $self->clients;
    for my $client (@clients) {
        $client->password($hash_pw);
        $client->save;
        $oauth->revoke_tokens_by_loginid($client->loginid);
    }

    # revoke refresh_token
    my $user_id = $self->{id};
    $oauth->revoke_refresh_tokens_by_user_id($user_id);

    $log = $is_reset_password ? 'Password has been reset' : 'Password has been changed';
    BOM::User::AuditLog::log($log, $self->email);

    return 1;
}

=head2 update_email

Updates user and client emails for a given user.

=over 4

=item * C<new_email> - new email

=back

Returns 1 on success

=cut

sub update_email {
    my ($self, $new_email) = @_;

    $new_email = lc $new_email;
    $self->update_email_fields(email => $new_email);
    my $oauth   = BOM::Database::Model::OAuth->new;
    my @clients = $self->clients(
        include_self_closed => 1,
        include_disabled    => 1,
        include_duplicated  => 1,
    );
    for my $client (@clients) {
        $client->email($new_email);
        $client->save;
        $oauth->revoke_tokens_by_loginid($client->loginid);
    }

    # revoke refresh_token
    my $user_id = $self->{id};
    $oauth->revoke_refresh_tokens_by_user_id($user_id);
    BOM::User::AuditLog::log('Email has been changed', $self->email);
    return 1;
}

=head2 update_trading_password

Calls a db function to store a hashed trading_password for the user.

=over 4

=item * C<trading_password> - new trading password

=back

Returns $self

=cut

sub update_trading_password {
    my ($self, $trading_password) = @_;

    die 'PasswordRequired' unless $trading_password;

    my $hash_pw = BOM::User::Password::hashpw($trading_password);

    $self->{trading_password} = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array('select trading_password from users.update_trading_password(?, ?, ?)', undef, $self->{id}, $hash_pw, undef);
        });

    return $self;
}

=head2 update_dx_trading_password

Calls a db function to store a hashed dx_trading_password for the user.

=over 4

=item * C<trading_password> - new trading password

=back

Returns $self

=cut

sub update_dx_trading_password {
    my ($self, $trading_password) = @_;

    die 'PasswordRequired' unless $trading_password;

    my $hash_pw = BOM::User::Password::hashpw($trading_password);

    $self->{dx_trading_password} = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array('select dx_trading_password from users.update_trading_password(?, ?, ?)', undef, $self->{id}, undef, $hash_pw);
        });

    return $self;
}

=head2 link_wallet_to_trading_account

Binds a wallet account to a trading account.

=over 4

=item * $args->{wallet_id} - a wallet loginid

=item * $args->{client_id} - a L<BOM::User::Client> or MT5 or DXtrade loginid

=back

Returns 1 on success, throws exception on error

=cut

sub link_wallet_to_trading_account {
    my ($self, $args) = @_;

    my $loginid        = delete $args->{client_id};
    my $wallet_loginid = delete $args->{wallet_id};

    my $wallet  = $self->get_wallet_by_loginid($wallet_loginid);
    my $account = $self->get_account_by_loginid($loginid);

    die "CannotLinkVirtualAndReal\n"
        unless (($loginid =~ '^(VR|MTD|DXD)' && $wallet->is_virtual)
        || ($loginid !~ '^(VR|MTD|DXD)' && !$wallet->is_virtual));

    die "CurrencyMismatch\n" unless ($account->{currency} eq $wallet->currency);

    my ($result);
    try {
        $result = $self->dbic->run(
            fixup => sub {
                $_->selectrow_array('select users.add_linked_wallet(?,?,?)', undef, $self->{id}, $account->{account_id}, $wallet->loginid);
            });
    } catch ($e) {
        $log->errorf('Fail to bind trading account %s to wallet account %s: %s', $account->{account_id}, $wallet->loginid, $e);
        die 'UnableToLinkWallet\n';
    }

    die "CannotChangeWallet\n" unless $result;

    delete $self->{linked_wallet};

    return 1;
}

=head2 get_wallet_by_loginid

Gets a wallet instance by loginid.

=over 4

=item * C<$loginid> - a L<BOM::User::Wallet> loginid

=back

Returns a L<BOM::User::Wallet> instance on success, throws exception on error

=cut

sub get_wallet_by_loginid {
    my ($self, $loginid) = @_;

    return (first { $_->is_wallet && $_->loginid eq $loginid } $self->clients or die "InvalidWalletAccount\n");
}

=head2 get_account_by_loginid

Gets a trading account by loginid.

=over 4

=item * C<$loginid> - a L<BOM::User::Client> or MT5 or DXtrade loginid

=back

Returns a hashref of Trading account details on success, throws exception on error

=cut

sub get_account_by_loginid {
    my ($self, $loginid) = @_;

    return BOM::TradingPlatform->new(
        platform => 'mt5',
        client   => $self->get_default_client
        )->get_account_info($loginid)->get
        if $loginid =~ MT5_REGEX;

    return BOM::TradingPlatform->new(
        platform => 'dxtrade',
        client   => $self->get_default_client
    )->get_account_info($loginid)
        if $loginid =~ DXTRADE_REGEX;

    my $client = first { $_->loginid eq $loginid && !$_->is_wallet } $self->clients;

    die "InvalidTradingAccount\n" unless ($client);

    my $account = $client->default_account;

    return {
        account_id      => $client->loginid,
        account_type    => $client->is_virtual ? 'demo'                                                             : 'real',
        balance         => $account            ? $account->balance                                                  : 0,
        currency        => $account            ? $account->currency_code                                            : '',
        display_balance => $account            ? formatnumber('amount', $account->currency_code, $account->balance) : '0.00',
        platform        => 'deriv',
    };
}

=head2 linked_wallet

Calls a db function to get a list of linked wallet for a user.

=over 4

=item * C<$loginid> - a L<BOM::User::Client> or L<BOM::User::Wallet> loginid

=back

Returns a list of linked wallet.

=cut

sub linked_wallet {
    my ($self, $wallet_loginid) = @_;

    return $self->{linked_wallet} if $self->{linked_wallet};

    $self->{linked_wallet} = $self->dbic->run(
        fixup => sub {
            return $_->selectall_arrayref(
                'select loginid, wallet_loginid from users.get_linked_wallet(?,?,?)',
                {Slice => {}},
                undef, $self->{id}, $wallet_loginid
            );
        });

    return $self->{linked_wallet};
}

=head2 get_trading_platform_loginids

Get all the recorded loginids for the given trading platform.

Takes the following arguments:

=over 4

=item * C<$platform> - the trading platform.

=item * C<$account_type> - either: real|demo|all, defaults to all.

=back

Returns a list of loginids.

=cut

sub get_trading_platform_loginids {
    my ($self, $platform, $account_type) = @_;
    $account_type //= 'all';

    my $regex_stash = {
        dxtrader => {
            real => DXTRADE_REAL_REGEX,
            demo => DXTRADE_DEMO_REGEX,
            all  => DXTRADE_REGEX,
        },
        mt5 => {
            real => MT5_REAL_REGEX,
            demo => MT5_DEMO_REGEX,
            all  => MT5_REGEX,
        }};

    my $regex = $regex_stash->{$platform}->{$account_type} or return ();

    return grep { $_ =~ qr/$regex/ } $self->loginids;
}

=head2 set_feature_flag

Sets the state of feature flag for the user as C<enabled> with current timestamp as C<stamp>

It takes the following named arguments

=over 1

=item * C<feature_flag> - hashref that contains key/value pair that represents feature_name/enabled

=back

Returns undef as we retreive those flags from C<get_feature_flag> subroutine

=cut

sub set_feature_flag {
    my ($self, $feature_flag) = @_;

    foreach my $feature_name (keys $feature_flag->%*) {
        $self->dbic->run(
            fixup => sub {
                $_->do('SELECT users.set_feature_flag(?, ?, ?)', undef, $self->{id}, $feature_name, $feature_flag->{$feature_name});
            });
    }

    return undef;
}

=head2 _get_default_flags

Returns hashref contains feature flags default value

=cut

sub _get_default_flags {
    my @flags = qw( wallet );

    return +{map { $_ => 0 } @flags};
}

=head2 get_feature_flag

Returns hashref that contains all feature flags details.
Retreive flag value from db. Otherwise default value is returned.

=cut

sub get_feature_flag {
    my ($self) = @_;

    my $result = $self->dbic->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT * FROM users.get_feature_flag(?)', {Slice => {}}, $self->{id});
        });

    return +{_get_default_flags->%*, map { $_->{name} => $_->{enabled} } $result->@*};
}

=head2 update_edd_status

Update users' EDD status

Returns a hashref of the users' updated EDD status

=cut

sub update_edd_status {
    my ($self, %args) = @_;

    if ($args{average_earnings}) {
        $args{average_earnings} = keys %{$args{average_earnings}} ? encode_json($args{average_earnings}) : undef;
    }

    return $self->dbic->run(
        fixup => sub {
            $_->do('SELECT users.update_edd_status(?, ?, ?, ?, ?, ?, ?)',
                undef, $self->{id}, @args{qw/status start_date last_review_date average_earnings comment reason/});
        });
}

=head2 get_edd_status

Returns a hashref of the most recent users' EDD status if exists, otherwise returns 0

=cut

sub get_edd_status {
    my $self = shift;
    try {
        return $self->dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM users.edd_status WHERE binary_user_id = ?', undef, $self->{id});
            }) // {};
    } catch {
        return 0;
    }
}

=head2 risk_screen

Gets the RiskScreen information of the current user.

=cut

sub risk_screen {
    my $self = shift;

    my ($risk_screen) = BOM::User::RiskScreen->find(binary_user_id => $self->id);

    return $risk_screen;
}

=head2 set_risk_screen

Prepares the current user to be monitored in RiskScreen.

=cut

sub set_risk_screen {
    my ($self, %args) = @_;

    my $old_values = $self->risk_screen // {};

    my $risk_screen = BOM::User::RiskScreen->new(%$old_values, %args, binary_user_id => $self->id);

    $risk_screen->save;

    return $risk_screen;
}

=head2 affiliate

Returns a hashref of a L<BOM::User> affiliate_id, and the coc_approval

=cut

sub affiliate {
    my $self = shift;

    return $self->{affiliate} if $self->{affiliate};

    $self->{affiliate} = $self->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM users.get_affiliate(?)', {Slice => {}}, $self->{id});
        });

    return $self->{affiliate};
}

=head2 set_affiliate_id

Sets the L<BOM::User> affiliate_id.

Note: The coc_approval is set to null by default because we don't know if the coc approval is needed or not.

This check is to be done manually by Compliance team.

=cut

sub set_affiliate_id {
    my ($self, $affiliate_id) = @_;

    try {
        return $self->dbic->run(
            fixup => sub {
                $_->do('SELECT FROM users.add_affiliate_id(?, ?)', undef, $self->{id}, $affiliate_id);
            });

    } catch {
        die +{code => 'AffiliateAlreadyExist'};
    }
}

=head2 set_affiliate_coc_approval

Sets the Affiliate & Payment Agent's Code of Conduct agreement as approved / needs approval.

Note: This is a different Code of Conduct agreement for Payment Agent only.

=cut

sub set_affiliate_coc_approval {
    my ($self, $coc_approval) = @_;

    die +{code => 'AffiliateNotFound'} unless $self->affiliate;

    $coc_approval //= 1;

    my $coc_version = '';    # putting '' as coc_version for now, maybe in future we'll have proper coc_version numbering

    return $self->dbic->run(
        fixup => sub {
            $_->do(
                'SELECT users.set_affiliate_coc_approval(?, ?, ?, ?)',
                undef,         $self->{id}, $self->affiliate->{affiliate_id},
                $coc_approval, $coc_version
            );
        });
}

=head2 affiliate_coc_approval_required

Returns 1 or 0 if the affiliate's approval to the Affiliate & Payment Agent's Code of Conduct agreement is required / needs approval

or returns undef if user is not an affiliate

=cut

sub affiliate_coc_approval_required {
    my $self = shift;

    return undef unless $self->affiliate;

    return undef unless defined $self->affiliate->{coc_approval};

    return $self->affiliate->{coc_approval} ? 0 : 1;
}

=head2 unlink_social

Returns 1 if user was unlinked for social providers.
Returns undef if user as no social providers.

=cut

sub unlink_social {
    my $user = shift;

    # remove social signup flag
    $user->update_has_social_signup(0);
    my $user_connect = BOM::Database::Model::UserConnect->new;
    my @providers    = $user_connect->get_connects_by_user_id($user->{id});

    # remove all other social accounts
    $user_connect->remove_connect($user->{id}, $_) for @providers;
    return 1;
}

1;
