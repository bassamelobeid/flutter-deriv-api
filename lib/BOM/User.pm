package BOM::User;

use strict;
use warnings;
no indirect;

use feature 'state';
use Syntax::Keyword::Try;
use Date::Utility;
use Format::Util::Numbers qw(formatnumber);
use List::Util            qw(first any all minstr uniq);
use Scalar::Util          qw(blessed looks_like_number);
use Carp                  qw(croak carp);
use Log::Any              qw($log);
use JSON::MaybeXS         qw(encode_json decode_json);

use BOM::Config::MT5;
use BOM::MT5::User::Async;
use BOM::Database::UserDB;
use BOM::Database::Model::UserConnect;
use BOM::User::Password;
use BOM::User::AuditLog;
use BOM::User::Static;
use BOM::User::Utility;
use BOM::User::Client;
use BOM::User::Wallet;
use BOM::User::Documents;
use BOM::User::Affiliate;
use BOM::User::Onfido;
use BOM::User::LexisNexis;
use BOM::User::SocialResponsibility;
use BOM::Config::Runtime;
use ExchangeRates::CurrencyConverter qw(convert_currency in_usd);
use BOM::Platform::Redis;
use LandingCompany::Registry;
use BOM::Config::AccountType::Registry;
use BOM::Platform::Context qw(request);
use Scalar::Util           qw(weaken);
use Exporter               qw( import );
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
# Redis key prefix for counting daily user amount transfers
use constant DAILY_TRANSFER_AMOUNT_KEY_PREFIX => "USER_TOTAL_AMOUNT_TRANSFERS_DAILY::";
use constant CACHED_FIELDS                    => qw(loginid_details affiliate);

# used for extracting numerical portion of MT5 loginids
use constant {
    MT5_REGEX => qr/^MT[DR]?(?=\d+$)/,
    EZR_REGEX => qr/^EZ[DR]?(?=\d+$)/,
};

sub dbic {
    my ($self, %params) = @_;

    # Cache connection to the database for object methods calls
    # This helps to avoid setting audit context every time we get connection from global cache
    if (ref $self) {
        my $key = 'dbic_' . ($params{db_operation} // 'write');
        $self->{$key} //= BOM::Database::UserDB::rose_db(%params)->dbic;
        return $self->{$key};
    }

    # For class methods, we use global connection cache
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

sub create {
    my ($class, %args) = @_;
    croak "email and password are mandatory" unless (exists($args{email}) && exists($args{password}));

    if ($args{utm_data}) {
        $args{utm_data} = keys %{$args{utm_data}} ? encode_json($args{utm_data}) : undef;
    }

    my @new_values = @args{@fields};
    shift @new_values;    #remove id value
    my $placeholders = join ",", ('?') x @new_values;

    my $sql    = "select * from users.create_user($placeholders)";    ## SQL safe($placeholders)
    my $result = $class->dbic->run(
        fixup => sub {
            $_->selectrow_hashref($sql, undef, @new_values);
        });

    my $self = bless $result, $class;

    if (my $context = $args{context}) {
        $context->user_registry->add_user($self);
        $self->{context} = $context;
        weaken($self->{context});
    }

    return $self;
}

=head2 new

Load a user record from db. There must be a key id, email or loginid

=cut

sub new {
    my ($class, %args) = @_;
    my $k = first { exists $args{$_} } qw(id email loginid);
    croak "no email nor id or loginid" unless $k;

    my $context = $args{context};
    if ($context && $k eq 'id') {
        my $user = $context->user_registry->get_user($args{id});
        return $user if $user;
    }

    if ($context && $k eq 'email') {
        my $user = $context->user_registry->get_user_by_email($args{email});
        return $user if $user;
    }

    # We're not implementing look up by loginid in the registry,
    # as it's not common in our codebase and cache hit by loginid is expected to be very low
    # Also to create index by loginid we need to hit one more table, which is not worth it
    # if this conditions will be different in future feel free to change it

    my $v = $args{$k};

    my $dbic = $class->dbic;
    my $self = $dbic->run(
        fixup => sub {
            $_->selectrow_hashref("select * from users.get_user_by_$k(?)", undef, $v);    ## SQL safe($k)
        });

    return undef unless $self;

    my $user = bless $self, $class;
    $user->{dbic_write} = $dbic;

    if ($context && $k eq 'loginid') {
        # We don't have index by loginid in registry, so we need to check if user is already there
        if (my $user = $context->user_registry->get_user($self->{id})) {
            return $user;
        }
    }

    if ($context) {
        $context->user_registry->add_user($self);
        $self->{context} = $context;
        weaken($self->{context});
    }

    return $user;
}

sub add_client {
    my ($self, $client, $link_to_wallet_loginid) = @_;
    croak('need a client') unless $client;

    my $account_type = $client->get_account_type;
    die 'client does not have a account type' unless $account_type;

    $self->add_loginid($client->loginid, $account_type->platform, undef, undef, undef, $link_to_wallet_loginid);
    return $self;
}

sub add_loginid {
    my ($self, $loginid, $platform, $account_type, $currency, $attributes, $link_to_wallet_loginid) = @_;
    croak('need a loginid') unless $loginid;
    $attributes = encode_json($attributes) if $attributes;

    my ($result) = $self->dbic->run(
        fixup => sub {
            return $_->selectrow_array('select users.add_loginid(?, ?, ?, ?, ?, ?, ?)',
                undef, $self->{id}, $loginid, $platform, $account_type, $currency, $attributes, $link_to_wallet_loginid);
        });

    delete $self->{loginid_details} if $result;
    return $self;
}

sub update_loginid_status {
    my ($self, $loginid, $status) = @_;
    croak('need a loginid') unless $loginid;

    $self->dbic->run(
        ping => sub {
            $_->do('select users.update_loginid_status(?, ?, ?)', undef, $loginid, $self->{id}, $status);
        });
    delete $self->{loginid_details};
    return $self;
}

=head2 broker_code_details

Parameter:

=over 4

=item * C<broker_code>

=back

Returns hashref of details about the broker code.

=cut

sub broker_code_details {
    my $broker_code = shift;

    my %details = (
        VRTC => {
            platform => 'dtrade',
            virtual  => 1
        },
        VRTJ => {
            platform => 'dtrade',
            virtual  => 1
        },
        VRTU => {
            platform => 'dtrade',
            virtual  => 1
        },
        CR  => {platform => 'dtrade'},
        MF  => {platform => 'dtrade'},
        MLT => {platform => 'dtrade'},
        MX  => {platform => 'dtrade'},
        JP  => {platform => 'dtrade'},
        AFF => {platform => 'dtrade'},
        VRW => {
            platform => 'dwallet',
            virtual  => 1,
            wallet   => 1
        },
        CRW => {
            platform => 'dwallet',
            wallet   => 1
        },
        CRA => {
            platform => 'dwallet',
            wallet   => 1
        },
        MFW => {
            platform => 'dwallet',
            wallet   => 1
        },
        MTD => {
            platform => 'mt5',
            virtual  => 1
        },
        MT  => {platform => 'mt5'},
        MTR => {platform => 'mt5'},
        DXD => {
            platform => 'dxtrade',
            virtual  => 1
        },
        DXR => {platform => 'dxtrade'},
        EZD => {
            platform => 'derivez',
            virtual  => 1
        },
        EZR => {
            platform => 'derivez',
        },
        CTD => {
            platform => 'ctrader',
            virtual  => 1
        },
        CTR => {platform => 'ctrader'},
    );

    return $details{$broker_code};
}

=head2 loginid_details

Get all loginids linked to the user with all fields.

The return is cached to avoid repeated db calls. Tests may need to delete $user->{loginid_details} to see changes.

Returns hashref.

=cut

sub loginid_details {
    my $self = shift;
    return $self->{loginid_details} if $self->{loginid_details};

    my $loginids = $self->dbic->run(
        fixup => sub {
            return $_->selectall_arrayref(
                'select loginid, platform, account_type, currency, attributes, status, creation_stamp, wallet_loginid from users.get_loginids(?)',
                {Slice => {}},
                $self->{id});
        });

    $self->{loginid_details} = {};

    for my $row (@$loginids) {
        my $loginid = $row->{loginid};
        ($row->{broker_code}) = $loginid =~ /(^[a-zA-Z]+)/;
        my $broker_info = broker_code_details($row->{broker_code}) or next;
        $row->{platform} //= $broker_info->{platform};
        $row->{account_type} //=
            '';    # we could set this based on broker code, but this could break code that relied on empty platform to filter out mt5 accounts
        $row->{is_virtual} = {
            demo => 1,
            real => 0
        }->{$row->{account_type}} // $broker_info->{virtual} ? 1 : 0;
        $row->{is_external} = $broker_info->{platform} !~ /^(dtrade|dwallet)$/ ? 1 : 0;
        $row->{is_wallet}   = $broker_info->{wallet}                           ? 1 : 0;
        $row->{attributes}  = decode_json($row->{attributes} // '{}');

        $self->{loginid_details}{$loginid} = $row;
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

=head2 create_client

Takes one or more named parameters:

=over 4

=item * C<landing_company> - e.g. `svg`

=back

=cut

sub create_client {
    my ($self, %args) = @_;
    $args{binary_user_id} = $self->{id};
    my $wallet_loginid = delete $args{wallet_loginid};
    $args{context} = $self->{context};

    my $client = BOM::User::Client->register_and_return_new_client(\%args);
    $self->add_client($client, $wallet_loginid);

    # Enable the trading_hub status if any siblings already has it enabled
    my $siblings = $client->get_siblings_information();
    for my $each_sibling (keys %{$siblings}) {
        my $sibling = $self->get_client_instance($each_sibling);
        if ($sibling->status->trading_hub) {
            $client->status->setnx('trading_hub', 'system', 'Enabling the Trading Hub');
            last;
        }
    }
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
        # Check for duplicates
        for my $account (values $self->loginid_details->%*) {
            next unless $account->{is_wallet};
            next unless $account->{is_virtual} == (($args{account_type} // '') eq 'demo' ? 1 : 0);
            my $wallet = $self->get_client_instance($account->{loginid}, 'replica');
            next unless $wallet->get_account_type->name eq ($args{account_type} // '');
            next unless $wallet->default_account;
            next unless $wallet->account->currency_code eq ($args{currency} // '');
            next unless $wallet->broker_code eq uc($args{broker_code}       // '');
            die +{error => 'DuplicateWallet'};
        }

        my $currency_code = delete $args{currency};
        $args{context} = $self->{context};
        my $wallet = BOM::User::Wallet->register_and_return_new_client(\%args);
        $wallet->set_default_account($currency_code);

        # in current back-end perspective wallet is a client
        $self->add_client($wallet);

        # Enable the trading_hub status if any siblings already has it enabled
        my $siblings = $wallet->get_siblings_information();
        for my $each_sibling (keys %{$siblings}) {
            my $sibling = $self->get_client_instance($each_sibling);
            if ($sibling->status->trading_hub) {
                $wallet->status->setnx('trading_hub', 'system', 'Enabling the Trading Hub');
                last;
            }
        }
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

    my $environment = $args{environment} || '';
    my $app_id      = $args{app_id}      || undef;

    my $skip_password =
           $args{is_passkeys_login}
        || $args{is_social_login}
        || $args{is_refresh_token_login}
        || 0;

    my $password = $skip_password ? undef : ($args{password} || die "requires password argument");

    use constant {
        MAX_FAIL_TIMES   => 5,
        ATTEMPT_INTERVAL => '5 minutes'
    };
    my $error;
    my $too_many_attempts = $self->dbic->run(
        fixup => sub {
            $_->selectrow_arrayref('select users.too_many_login_attempts(?::BIGINT, ?::SMALLINT, ?::INTERVAL)',
                undef, $self->{id}, MAX_FAIL_TIMES, ATTEMPT_INTERVAL)->[0];
        });

    if ($too_many_attempts) {
        $error = 'LoginTooManyAttempts';
    } elsif (!$skip_password && !BOM::User::Password::checkpw($password, $self->{password})) {
        $error = 'INVALID_CREDENTIALS';
    } elsif (!($self->clients)) {
        $error = $self->clients(include_self_closed => 1) ? 'AccountSelfClosed' : 'AccountUnavailable';
    }

    $self->after_login($error, $environment, $app_id);

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

It takes following args:

=over 4

=item * C<$error> - The error code if there's any; B<undef> or 0 if login was successful.

=item * C<$environment> - The runtime environment of the requesting web client represented as a string.

=item * C<$app_id> - The application id used in websocket connection.

=item * C<@clients> - An array consisting of the matched client objects (for successful login only).

=back

=cut

sub after_login {
    my ($self, $error, $environment, $app_id) = @_;
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

    return map { $self->get_client_instance($_, $args{db_operation} // 'write') }
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

get client non-platform login ids

=cut

sub bom_loginids {
    my $self = shift;

    my %details = $self->loginid_details->%*;
    return grep { !$details{$_}{is_external} } sort keys %details;
}

=head2 bom_real_loginids

get non-platform real login ids

=cut

sub bom_real_loginids {
    my $self = shift;

    my %details = $self->loginid_details->%*;
    return grep { !$details{$_}{is_virtual} && !$details{$_}{is_external} } sort keys %details;
}

=head2 bom_virtual_loginid

get legacy virtual login id

=cut

sub bom_virtual_loginid {
    my $self = shift;

    my %details = $self->loginid_details->%*;
    return first { $details{$_}{is_virtual} && $details{$_}{platform} eq 'dtrade' } sort keys %details;
}

=head2 bom_virtual_wallet_loginid

get virtual wallet login ids

=cut

sub bom_virtual_wallet_loginid {
    my $self = shift;

    my %details = $self->loginid_details->%*;
    return first { $details{$_}{is_wallet} && $details{$_}{is_virtual} && !$details{$_}{is_external} } sort keys %details;
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

sub get_last_successful_login_history {
    my $self = shift;

    return $self->dbic->run(fixup => sub { $_->selectrow_hashref('SELECT * FROM users.get_last_successful_login_history(?)', undef, $self->{id}) });
}

=head2 has_mt5_regulated_account

Check if user has any mt5 regulated account - currently its only Labuan (deprecated).

If a truthy C<use_mt5_conf> flag is given, it will filter using the mt5 conf (as it should've been).

Returns a boolean value.

=cut

sub has_mt5_regulated_account {
    my ($self, %args) = @_;

    my $params = {
        type_of_account => 'real',
        regexes         => [],
        full_match      => []};

    if ($args{use_mt5_conf}) {
        my $mt5_config = BOM::Config::MT5->new;
        $params->{full_match} = [uniq map { $mt5_config->available_groups({company => $_, server_type => 'real'}, 1) } qw/bvi labuan vanuatu/];
    } else {
        # these regexes seems to be way outdated
        $params->{regexes} = ['^(?!demo)[a-z]+\\\\(?!svg)[a-z]+(?:_financial)', '^real(\\\\p01_ts)?(?:01|02|03|04)\\\\financial\\\\(?!svg)'];
    }

    return $self->has_mt5_groups($params->%*);
}

=head2 has_mt5_groups

Checks if the user has the desired groups by account type, it takes the following arguments as hash:

=over 4

=item * C<type_of_account> by default `all`, can be also `real` or `demo`

=item * C<regexes> arrayref of regexes (mandatory otherwise the function is pointless)

=item * C<full_match> arrayref of groups to filter

=back

Returns a boolean value

=cut

sub has_mt5_groups {
    my ($self, %args) = @_;

    $args{type_of_account} //= 'all';
    $args{regexes}         //= [];
    $args{full_match}      //= [];

    # no point in checking if there is not filtering condition
    return 0 unless scalar $args{full_match}->@* || scalar $args{regexes}->@*;

    my @all_mt5_loginids = $self->get_mt5_loginids(%args);

    return 0 unless @all_mt5_loginids;

    my $login_accs = $self->loginid_details;

    # hashify the groups
    my $groups = +{map { $login_accs->{$_}->{attributes}->{group} ? ($login_accs->{$_}->{attributes}->{group} => 1) : () } @all_mt5_loginids};

    return 1 if any { defined $groups->{$_} } $args{full_match}->@*;

    # cut here if empty regexes
    return 0 unless scalar $args{regexes}->@*;

    # glue the regexes into the big one
    my $big_regex = join '|', map { "($_)" } $args{regexes}->@*;

    return 1 if any { $_ =~ qr/$big_regex/ } keys $groups->%*;

    return 0;
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

        my $cl = $self->get_client_instance($loginid, $args{db_operation} // 'write');
        next unless $cl;

        next if (!$args{include_duplicated} && $cl->status->is_login_disallowed);

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

=head2 get_client_instance

Get client instance from cache if exists, otherwise create new instance and cache it



Arguments:

=over 4

=item * C<loginid> - client loginid

=item * C<db_operation> - defaults to write.

=back

Returns client instance

=cut

sub get_client_instance {
    my ($self, $loginid, $db_operation) = @_;
    $db_operation //= 'write';

    return BOM::User::Client->get_client_instance($loginid, $db_operation, $self->{context});
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
    my $limit = looks_like_number($args{limit}) ? "limit ?" : '';
    my $sql   = "select * from users.get_login_history(?,?,?) $limit";    ## SQL safe($limit)
    return $self->dbic(operation => 'replica')->run(
        fixup => sub {
            $_->selectall_arrayref($sql, {Slice => {}}, $self->{id}, $args{order}, $args{show_impersonate_records} // 0,
                $limit ? ($args{limit}) : ());
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
    my $sql          = "select * from users.add_login_history($placeholders)";    ## SQL safe($placeholders)
    $self->dbic->run(
        fixup => sub {
            $_->do($sql, undef, @new_values);
        });
    return $self;
}

=head2 get_siblings_for_transfer

For a client, returns a list of of client objects allowed for transfer between accounts.

=over 4

=item * C<client>

=back

=cut

sub get_siblings_for_transfer {
    my ($self, $client) = @_;

    my %loginid_details = $self->loginid_details->%*;
    my @loginids        = grep { $_ ne $client->loginid && !$loginid_details{$_}->{is_external} } keys %loginid_details;
    @loginids = grep { $loginid_details{$_}->{is_virtual} == $client->is_virtual } @loginids;

    if ($client->is_legacy) {
        @loginids = grep { !$loginid_details{$_}->{is_wallet} } @loginids;
        @loginids = grep { !$loginid_details{$_}->{wallet_loginid} } @loginids;
    } elsif ($client->is_wallet) {
        @loginids = grep { (($loginid_details{$_}->{wallet_loginid} // '') eq $client->loginid) || $loginid_details{$_}->{is_wallet} } @loginids;
    } elsif ($client->get_account_type->name eq 'standard') {
        @loginids = grep { $_ eq ($loginid_details{$client->loginid}->{wallet_loginid} // '') } @loginids;
    } else {
        $log->warnf('Unhandled client %s passed to get_siblings_for_transfer', $client->loginid);
        die +{error => 'InternalServerError'};
    }

    my @clients = map { $self->get_client_instance($_, 'replica') } @loginids;
    @clients = grep { !$_->status->disabled && !$_->status->duplicate_account } @clients;
    @clients = grep { $_->get_account_type->transfers ne 'none' } @clients;
    @clients = grep { $_->landing_company->short eq $client->landing_company->short } @clients;

    push @clients, $client;    # own account is always returned

    return @clients;
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
        $oauth->revoke_tokens_by_loignid_and_ua_fingerprint($_->loginid, $args{ua_fingerprint}) for ($self->clients);
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

my $loginids = Reference list of all accounts associated with current client account;

=over

=item * C<$login_id> client login id to check status

=back

Returns  boolean value

=cut

sub filter_active_ids {
    my ($self, $loginids) = @_;

    return [grep { $self->is_active_loginid($_) } @$loginids];
}

=head2 is_active_loginid

Predicate to check login id status based on the state we have in user db

=over

=item * C<$login_id> client login id to check status

=back

Returns  boolean value

=cut

sub is_active_loginid {
    my ($self, $loginid) = @_;

    my $details = $self->loginid_details->{$loginid};

    return 0 unless $details;

    # Currently we have statuses only for mt5 and derivez accounts
    return 1 unless $details->{platform} =~ /^(?:mt5|derivez)$/;

    # Since there are no plans to add "active" to status of active account in DB, current active accounts
    # contain status of 'undef'.
    return 1 unless $details->{status};

    return 1
        if any { $details->{status} eq $_ }
        qw/poa_outdated poa_pending poa_rejected poa_failed proof_failed verification_pending needs_verification migrated_with_position migrated_without_position/;

    return 0;
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

    my @loginids = sort $self->get_trading_platform_loginids(
        platform => 'mt5',
        %args
    );

    return @loginids;
}

=head2 get_derivez_loginids

Getting derivez accounts based on their type_of_account

=cut

sub get_derivez_loginids {
    my ($self, %args) = @_;

    my @loginids = sort $self->get_trading_platform_loginids(
        platform => 'derivez',
        %args
    );

    return @loginids;
}

=head2 get_dxtrade_loginids

Getting dxtrade accounts based on their type_of_account

=cut

sub get_dxtrade_loginids {
    my ($self, %args) = @_;

    my @loginids = sort $self->get_trading_platform_loginids(
        platform => 'dxtrade',
        %args
    );

    return @loginids;
}

=head2 get_ctrader_loginids

Getting ctrader accounts based on their type_of_account

=cut

sub get_ctrader_loginids {
    my ($self, %args) = @_;

    my @loginids = sort $self->get_trading_platform_loginids(
        platform => 'ctrader',
        %args
    );

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
    } catch ($e) {
        $log->warnf("Failed to store user login entry in redis, error: %s", $e);
    }
}

=head2 logged_in_before_from_same_location

Checks where the user have logged in from the same location before

=cut

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

        my $previous_env             = $last_attempt_in_db->{environment};
        my $last_attempt_entry       = BOM::User::Utility::login_details_identifier($previous_env);
        my $last_attempt_env_info    = BOM::User::Utility::get_details_from_environment($previous_env);
        my $current_attempt_env_info = BOM::User::Utility::get_details_from_environment($new_env);

        my $last_attempt_device_id    = $last_attempt_env_info->{device_id};
        my $last_attempt_ip           = $last_attempt_env_info->{ip};
        my $current_attempt_device_id = $current_attempt_env_info->{device_id};
        my $current_attempt_ip        = $current_attempt_env_info->{ip};

        # Ignore device id check, when previous env do not have device info
        $entry =~ s/::$current_attempt_device_id$//ig if ($current_attempt_device_id && !$last_attempt_device_id);
        # Ignore ip check, when previous env do not have IP address
        $entry =~ s/::$current_attempt_ip//ig if ($current_attempt_ip && !$last_attempt_ip);

        return 1 if $last_attempt_entry eq $entry;
    } catch ($e) {
        $log->warnf("Failed to get user login entry from redis, error: %s", $e);
    }

    return $attempt_known;
}

=head2 daily_transfer_incr

Increments transfers per day. Taakes the following parameters:

=over 4

=item * C<client_from> - client instance

=item * C<loginid_from> - if client_from not provided

=item * C<client_to> - client instance

=item * C<loginid_to> - if client_to not provided

=item * C<amount> - amount transferred, can be negative

=item * C<amount_currency> - currency of amount

=back

=cut

sub daily_transfer_incr {
    my ($self, %args) = @_;

    my $limit_type = $self->get_transfer_limit_type(%args);
    my $amount     = abs(convert_currency($args{amount}, $args{amount_currency}, 'USD'));

    # redis name is different than dynamic settings
    # Everyone's limits will be reset to zero if setting is changed. So we should always be incrementing both keys always.
    # It's a waste of space but we have no choice until we remove the old code.

    $self->daily_transfer_incr_count($limit_type->{type}, $limit_type->{identifier});
    $self->daily_transfer_incr_amount($amount, $limit_type->{type}, $limit_type->{identifier});

    return;
}

=head2 daily_transfer_incr_count

Increments number of transfers per day in redis.

=cut

sub daily_transfer_incr_count {
    my ($self, $type, $identifier) = @_;

    my $redis     = BOM::Config::Redis::redis_replicated_write();
    my $redis_key = DAILY_TRANSFER_COUNT_KEY_PREFIX . $type . '_' . $identifier;
    my $expiry    = Date::Utility->today->plus_time_interval('1d')->epoch - 1;     #end of day - 1 sec

    $redis->multi;
    $redis->incr($redis_key);
    $redis->expireat($redis_key, $expiry);
    $redis->exec;

    return;
}

=head2 daily_transfer_incr_amount

Increments daily transfer amount in redis.

=cut

sub daily_transfer_incr_amount {
    my ($self, $amount, $type, $identifier) = @_;

    my $redis          = BOM::Config::Redis::redis_replicated_write();
    my $redis_hash     = DAILY_TRANSFER_AMOUNT_KEY_PREFIX . Date::Utility->new->date;
    my $redis_hash_key = $type . '_' . $identifier;
    my $expiry         = Date::Utility->today->plus_time_interval('1d')->epoch - 1;     #end of day - 1 sec

    $redis->multi;
    $redis->hincrbyfloat($redis_hash, $redis_hash_key, $amount);                        # amount is USD
    $redis->expireat($redis_hash, $expiry);
    $redis->exec;

    return;
}

=head2 get_transfer_limit_type

Returns a hash of information for recording or checking daily transfer limits.
This is determined by the account types of both clients.

=over 4

=item * C<client_from> - client instance

=item * C<loginid_from> - if client_from not provided

=item * C<client_to> - client instance

=item * C<loginid_to> - if client_to not provided

=back

=cut

sub get_transfer_limit_type {
    my ($self, %args) = @_;

    $args{loginid_from} //= $args{client_from}->loginid;
    $args{loginid_to}   //= $args{client_to}->loginid;
    my $details         = $self->loginid_details;
    my $details_from    = $details->{$args{loginid_from}} or return undef;
    my $details_to      = $details->{$args{loginid_to}}   or return undef;
    my $from_is_cashier = $args{client_from} ? $args{client_from}->get_account_type->is_cashier : -1;
    my $to_is_cashier   = $args{client_to}   ? $args{client_to}->get_account_type->is_cashier   : -1;

    my $type       = 'internal';
    my $identifier = $self->id;

    if (any { $_->{is_virtual} } ($details_from, $details_to)) {
        $type = 'virtual';
    } elsif ((all { $_->{is_wallet} } ($details_from, $details_to)) and any { $_ == 0 } ($from_is_cashier, $to_is_cashier)) {
        $type = 'wallet';    # transfer from a cashier wallet to a non-cashier wallet (p2p or payment_agent)
    } elsif (any { $_->{platform} eq 'mt5' } ($details_from, $details_to)) {
        $type = 'MT5';       # uppercase name is used for redis keys and config
    } elsif (any { $_->{platform} eq 'dtrade' && $_->{wallet_loginid} } ($details_from, $details_to)) {
        $type = 'dtrade';
    } elsif (my $acc = first { $_->{is_external} } ($details_from, $details_to)) {
        $type = $acc->{platform};    # dxtrade/derivez/ctrade are used as is
    }

    if ($type !~ /^(virtual|internal|wallet)$/) {
        $identifier = $details_from->{wallet_loginid} // $details_to->{wallet_loginid} // $identifier;
    }

    my $config_name = {
        internal => 'between_accounts',
        wallet   => 'between_wallets',
    }->{$type} // $type;

    return {
        type        => $type,
        identifier  => $identifier,
        config_name => $config_name,
    };

}

=head2 daily_transfer_count

Gets number of transfers made in the current day.

=cut

sub daily_transfer_count {
    my ($self, %args) = @_;

    my $redis     = BOM::Config::Redis::redis_replicated_write();
    my $redis_key = DAILY_TRANSFER_COUNT_KEY_PREFIX . $args{type} . '_' . $args{identifier};

    return $redis->get($redis_key) // 0;
}

=head2 daily_transfer_amount

Gets total transfer amount made in the current day.

=cut

sub daily_transfer_amount {
    my ($self, %args) = @_;

    my $redis          = BOM::Config::Redis::redis_replicated_write();
    my $redis_hash     = DAILY_TRANSFER_AMOUNT_KEY_PREFIX . Date::Utility->new->date;
    my $redis_hash_key = $args{type} . '_' . $args{identifier};

    return $redis->hget($redis_hash, $redis_hash_key) // 0;
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
        $cl = $self->get_client_instance($login_id, 'replica');
    } catch ($e) {
        $log->warnf("Error getting replica connection: %s", $e);
        $error = $e;
    }

    # try master if replica is down
    $cl = $self->get_client_instance($login_id, 'write') if not $cl or $error;

    return $cl;
}

=head2 total_trades

get the total value of all trades of this user

=over

=item C<start_date> - (required) starting date from which we need to calculate total trade

=back

total value of all trades in USD

=cut

sub total_trades {
    my ($self, $start_date) = @_;

    my @clients = $self->clients(include_disabled => 0);

    # filter out virtual clients
    @clients = grep { not $_->is_virtual } @clients;

    my $total = 0;
    for my $client (@clients) {
        # Check if client has no currency code
        next unless $client->account;

        my $replica_client = $self->get_client_using_replica($client->loginid);
        my ($amount) = $replica_client->db->dbic->run(
            fixup => sub {
                $_->selectrow_array('SELECT * FROM bet.get_total_trades(?, ?)', undef, $client->account->id, $start_date);
            });
        $total += in_usd($amount, $client->currency) if $amount;
    }
    return $total;
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
    my $vr_clients = first { $_->is_virtual } $self->clients;    # can be vrtc or vrw
    my $loginid    = $vr_clients->{loginid};
    if ($loginid) {
        my $client = $self->get_client_instance($loginid);
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

    # TODO: the purpose of this will be reconsidered in latter cards. the idea to avoid having orphan account
    # in light of this fact, we probably will need this sub only for migration logic.

    my $loginid        = delete $args->{client_id};
    my $wallet_loginid = delete $args->{wallet_id};

    my $wallet = $self->get_wallet_by_loginid($wallet_loginid);

    die "InvalidWalletAccount\n" unless $wallet;

    my $account_details = $self->loginid_details->{$loginid};
    die "InvalidTradingAccount\n" unless $account_details;

    my $currency;
    if ($account_details->{is_external}) {
        # Handling trading platforms acounts
        $currency = $account_details->{currency};

        unless ($currency) {
            # Fallsback for legacy accounts, usually mt5
            my $platform_acc = BOM::TradingPlatform->new(
                platform => $account_details->{platform},
                client   => $self->get_default_client,
                user     => $self,
            )->get_account_info($loginid);

            $currency = $platform_acc->{currency} // '';
        }
    } else {
        # Handling internal accounts
        my $client = $self->get_client_instance($loginid);
        my $acc    = $client->default_account;
        $currency = $acc ? $acc->currency_code : '';
    }

    die "CannotLinkVirtualAndReal\n" unless $account_details->{is_virtual} == $wallet->is_virtual;

    die "CurrencyMismatch\n" unless $currency eq $wallet->currency;

    my ($result);
    try {
        $result = $self->dbic->run(
            fixup => sub {
                $_->selectrow_array('select users.add_linked_wallet(?,?,?)', undef, $self->{id}, $loginid, $wallet_loginid);
            });
    } catch ($e) {
        $log->errorf('Fail to bind trading account %s to wallet account %s: %s', $loginid, $wallet_loginid, $e);
        die 'UnableToLinkWallet\n';
    }

    die "CannotChangeWallet\n" unless $result;

    delete $self->@{qw(linked_wallet loginid_details)};

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
    my ($self, $loginid, $args) = @_;

    die "InvalidWalletAccount\n" unless $self->loginid_details->{$loginid};

    return $self->get_client_instance($loginid, $args->{db_operation} // 'write');
}

=head2 get_account_by_loginid

Gets trading account details (including balance) by loginid.

=over 4

=item * C<$loginid> - a L<BOM::User::Client> or MT5 or DXtrade loginid

=back

Returns a hashref of Trading account details on success, throws exception on error

=cut

sub get_account_by_loginid {
    my ($self, $loginid) = @_;

    # Using `require` to import at runtime and avoid circular dependency
    require BOM::TradingPlatform;

    my $details = $self->loginid_details->{$loginid};
    die "InvalidTradingAccount\n" if !$details || $details->{is_wallet};

    if ($details->{is_external}) {
        return BOM::TradingPlatform->new(
            platform => $details->{platform},
            client   => $self->get_default_client,
            user     => $self,
        )->get_account_info($loginid);
    }

    my $client = first { $_->loginid eq $loginid && !$_->is_wallet } $self->clients;
    die "InvalidTradingAccount\n" unless $client;

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

=head2 get_accounts_links

Returns a hash where keys are representing loginid of accounts and values are arrays with linked accounts.

=cut

sub get_accounts_links {
    my ($self) = @_;

    my %details  = $self->loginid_details->%*;
    my @loginids = sort keys %details;
    my %result;

    for my $loginid (@loginids) {
        # Checking that trading account is active, currently is applicable only for mt5 and derivez
        # In future may worth to add wallet check here as well, if we'll keep statuses at userdb
        next unless $self->is_active_loginid($loginid);

        my $item = +{
            loginid  => $loginid,
            platform => $details{$loginid}{platform},
        };

        if (my $wallet_loginid = $details{$loginid}{wallet_loginid}) {
            push $result{$wallet_loginid}->@*, $item;
            next;
        }

        if (my @children = grep { ($details{$_}{wallet_loginid} // '') eq $loginid } @loginids) {
            push $result{$_}->@*, $item for @children;
        }
    }

    return \%result;
}

=head2 migrate_loginid

Migrates a trading account to wallet flow by populating information in users.loginid table 
and linking trading account to the wallet account.

=over 4

=item * C<$args> - hash with the following keys:

=over 4

=item * C<loginid> - trading account loginid

=item * C<platform> - trading platform

=item * C<account_type> - trading account type

=item * C<wallet_loginid> - wallet account loginid

=back

=back

Returns 1 on success, throws exception on error

=cut

sub migrate_loginid {

    my ($self, %args) = @_;

    $args{$_} || croak "Missing $_" for qw(loginid platform account_type wallet_loginid);

    my ($res) = $self->dbic->run(
        fixup => sub {
            return $_->selectrow_array('select users.migrate_loginid(?,?,?,?,?)',
                undef, $self->{id}, @args{qw(loginid platform account_type wallet_loginid)});
        });

    # only should happen if we start to migration for the same user in parallel.
    # but it should not be possible as we have redis lock preventing this.
    croak "Unable to link $args{loginid} to $args{wallet_loginid}" unless $res;

    return 1;
}

=head2 get_trading_platform_loginids

Get all the recorded loginids for the given trading platform.

Takes the following named arguments:

=over 4

=item * C<platform> - the trading platform.

=item * C<type_of_account> - either: real|demo|all, defaults to all.

=item * C<loginid> - filter by loginid.

=item * C<include_all_status> - inactive accounts will be filtered out unless true.

=item * C<wallet_loginid> - if param exists and is defined, only accounts linked to the wallet are returned. If it exists and is undefined, all unlinked accounts are returned. If it does not exist, both linked and unlinked accounts belonging to user are returned.

=back

Returns a list of loginids.

=cut

sub get_trading_platform_loginids {
    my ($self, %args) = @_;

    my @loginids;

    for my $account (values $self->loginid_details->%*) {
        next if $args{platform} ne $account->{platform};

        next if ($args{type_of_account} // '') eq 'real' && $account->{is_virtual};
        next if ($args{type_of_account} // '') eq 'demo' && !$account->{is_virtual};

        next if !$args{include_all_status} && !$self->is_active_loginid($account->{loginid});

        next if $args{loginid} and $args{loginid} ne $account->{loginid};

        next if exists $args{wallet_loginid} && ($args{wallet_loginid} // '') ne ($account->{wallet_loginid} // '');

        push @loginids, $account->{loginid};
    }

    return @loginids;
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

=head2 update_reputation_status

Update users' reputation status

Returns a hashref of the users' updated reputation status

=cut

sub update_reputation_status {
    my ($self, %args) = @_;

    my $query = 'SELECT users.update_affiliate_reputation(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

    my @params = (
        $self->{id},
        @args{
            qw/reputation_check
                reputation_check_status
                reputation_check_type
                social_media_check
                company_owned
                criminal_record
                civil_case_record
                fraud_scam
                start_date
                last_review_date
                reference/
        });

    return $self->dbic->run(
        fixup => sub {
            $_->do($query, undef, @params);
        });
}

=head2 get_reputation_status

Returns a hashref of the most recent users' reputation status if exists, otherwise returns 0

=cut

sub get_reputation_status {
    my $self = shift;
    try {
        return $self->dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM users.affiliate_reputation WHERE binary_user_id = ?', undef, $self->{id});
            }) // {};
    } catch {
        return 0;
    }
}

=head2 lexis_nexis

Gets the LexisNexis information of the current user.

=cut

sub lexis_nexis {
    my $self = shift;

    my ($lexis_nexis) = BOM::User::LexisNexis->find(binary_user_id => $self->id);

    return $lexis_nexis;
}

=head2 set_lexis_nexis

Prepares the current user to be monitored in LexisNexis.

=cut

sub set_lexis_nexis {
    my ($self, %args) = @_;

    my $old_values = $self->lexis_nexis // {};

    my $lexis_nexis = BOM::User::LexisNexis->new(%$old_values, %args, binary_user_id => $self->id);

    $lexis_nexis->save;
    return $lexis_nexis;
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

    $self->dbic->run(
        fixup => sub {
            $_->do('SELECT FROM users.set_affiliate_id(?, ?)', undef, $self->{id}, $affiliate_id);
        });

    delete $self->{affiliate};

    return;
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

    my $res = $self->dbic->run(
        fixup => sub {
            $_->do(
                'SELECT users.set_affiliate_coc_approval(?, ?, ?, ?)',
                undef, $self->{id}, $self->affiliate->{affiliate_id},
                $coc_approval, $coc_version
            );
        });

    delete $self->{affiliate};

    return $res;
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

=head2 oneall_data

Fetch oneall data for an user in users.binary_user_connects

=cut

sub oneall_data {
    my ($self) = shift;

    my $oneall_data = $self->dbic->run(
        fixup => sub {
            $_->selectall_arrayref("SELECT * FROM users.get_user_oneall_provider_data(?)", {Slice => {}}, $self->id);
        });

    my @user_data;

    for my $data (@$oneall_data) {
        try {
            my $json_obj = decode_json($data->{provider_data});
            push(
                @user_data,
                {
                    binary_user_id => $self->id,
                    user_token     => $json_obj->{user}->{user_token},
                    provider       => $data->{provider}});
        } catch ($e) {
            $log->errorf('Failed to decode provider_data: %s', $e);
        }
    }
    return \@user_data;
}

=head2 documents

Accessor for the L<BOM::User::Documents> package.

Not to be confused with L<BOM::User::Client::AuthenticationDocuments> which manages documents at the LC level.

=cut

sub documents {
    my $self = shift;

    return $self->{documents} //= do {
        $self->{documents} = BOM::User::Documents->new({
            user => $self,
        });
    };
}

1;
