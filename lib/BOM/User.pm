package BOM::User;

use strict;
use warnings;
no indirect;

use feature 'state';
use Syntax::Keyword::Try;
use Date::Utility;
use List::Util qw(first any all minstr);
use Scalar::Util qw(blessed looks_like_number);
use Carp qw(croak carp);
use Log::Any qw($log);
use JSON::MaybeXS qw(encode_json decode_json);

use BOM::MT5::User::Async;
use BOM::Database::UserDB;
use BOM::User::Password;
use BOM::User::AuditLog;
use BOM::User::Static;
use BOM::User::Utility;
use BOM::User::Client;
use BOM::User::Onfido;
use BOM::Config::Runtime;
use ExchangeRates::CurrencyConverter qw(in_usd);
use LandingCompany::Registry;
use BOM::Platform::Context qw(request);
use Exporter qw( import );
our @EXPORT_OK = qw( is_payment_agents_suspended_in_country );

# Backoffice Application Id used in some login cases
use constant BACKOFFICE_APP_ID => 4;
# Redis key prefix for client's previous login attempts
use constant CLIENT_LOGIN_HISTORY_KEY_PREFIX => "CLIENT_LOGIN_HISTORY::";
# Redis key prefix for counting daily user transfers
use constant DAILY_TRANSFER_COUNT_KEY_PREFIX => "USER_TRANSFERS_DAILY::";

sub dbic {
    #not caching this as the handle is cached at a lower level and
    #if it does cache a bad handle here it will not recover.
    return BOM::Database::UserDB::rose_db()->dbic;
}

=head2 create

Create new record in table users.binary_user

=cut

my @fields =
    qw(id email password email_verified utm_source utm_medium utm_campaign app_id email_consent gclid_url has_social_signup secret_key is_totp_enabled signup_device date_first_contact);

# generate attribute accessor
for my $k (@fields) {
    no strict 'refs';
    *{__PACKAGE__ . '::' . $k} = sub { shift->{$k} }
        unless __PACKAGE__->can($k);
}

use constant {
    MT5_REGEX     => qr/^MT[DR]?(?=\d+$)/,
    VIRTUAL_REGEX => qr/^VR/,
};

sub create {
    my ($class, %args) = @_;
    croak "email and password are mandatory" unless (exists($args{email}) && exists($args{password}));
    my @new_values = @args{@fields};
    shift @new_values;    #remove id value
    my $placeholders = join ",", ('?') x @new_values;

    if ($args{utm_data} && keys %{$args{utm_data}}) {
        push @new_values => encode_json($args{utm_data});
        $placeholders .= ",?::JSONB";
    }

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
    my ($self, $loginid) = @_;
    croak('need a loginid') unless $loginid;
    my ($result) = $self->dbic->run(
        fixup => sub {
            return $_->selectrow_array('select users.add_loginid(?,?)', undef, $self->{id}, $loginid);
        });
    push @{$self->{loginids}}, $result if ($self->{loginids} && $result);
    return $self;
}

sub loginids {
    my $self = shift;
    return @{$self->{loginids}} if $self->{loginids};
    $self->{loginids} = $self->dbic->run(
        fixup => sub {
            return $_->selectcol_arrayref('select loginid from users.get_loginids(?)', undef, $self->{id});
        });
    return @{$self->{loginids}};
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

=head2 login

Check user credentials.
Returns hashref, {success => 1} if successfully authenticated user or {error => 'failed reason'} otherwise.

=cut

sub login {
    my ($self, %args) = @_;

    my $password        = $args{password}        || die "requires password argument";
    my $environment     = $args{environment}     || '';
    my $is_social_login = $args{is_social_login} || 0;
    my $app_id          = $args{app_id}          || undef;

    use constant {
        MAX_FAIL_TIMES   => 5,
        ATTEMPT_INTERVAL => '5 minutes'
    };
    my @clients;
    my ($error, $log_as_failed) = (undef, 1);
    my $too_many_attempts = $self->dbic->run(
        fixup => sub {
            $_->selectrow_arrayref('select users.too_many_login_attempts(?::BIGINT, ?::SMALLINT, ?::INTERVAL)',
                undef, $self->{id}, MAX_FAIL_TIMES, ATTEMPT_INTERVAL)->[0];
        });
    if ($too_many_attempts) {
        $error         = 'LoginTooManyAttempts';
        $log_as_failed = 0;
    } elsif (!$is_social_login && !BOM::User::Password::checkpw($password, $self->{password})) {
        $error = 'IncorrectEmailPassword';
    } elsif (!(@clients = $self->clients)) {
        $error = 'AccountUnavailable';
    } else {
        $log_as_failed = 0;
    }

    state $error_mapping  = BOM::User::Static::get_error_mapping();
    state $error_log_msgs = {
        LoginTooManyAttempts   => "failed login > " . MAX_FAIL_TIMES . " times",
        IncorrectEmailPassword => 'incorrect email or password',
        AccountUnavailable     => 'Account disabled',
        Success                => 'successful login',
    };
    BOM::User::AuditLog::log($error_log_msgs->{$error || 'Success'}, $self->{email});
    $self->dbic->run(
        fixup => sub {
            $_->do('select users.record_login_history(?,?,?,?,?)', undef, $self->{id}, $error ? 'f' : 't', $log_as_failed, $environment, $app_id);
        });
    return {error => $error_mapping->{$error}} if $error;
    # store this login attempt in redis
    $self->_save_login_detail_redis($environment);

    my $countries_list = request()->brand->countries_instance->countries_list;
    my $gamstop_client = first {
        my $client = $_;
        any { $client->landing_company->short eq $_ } ($countries_list->{$client->residence}->{gamstop_company} // [])->@*
    }
    @clients;
    BOM::User::Utility::set_gamstop_self_exclusion($gamstop_client) if $gamstop_client;
    return {success => 1};
}

=head2 clients

Get my enabled client objects, in loginid order but with reals up first.  Use the replica db for speed.

=over 4

=item * C<include_disabled> - e.g. include_disabled=>1  will include disableds otherwise not.

=item * C<include_duplicated> - e.g. include_duplicated=>1  will include duplicated otherwise not.

=back

Returns client objects array

=cut

sub clients {
    my ($self, %args) = @_;
    my $include_duplicated = $args{include_duplicated} // 0;

    my @clients = @{$self->get_clients_in_sorted_order(include_duplicated => $include_duplicated)};

    # todo should be refactor
    @clients = grep { not $_->status->disabled } @clients unless $args{include_disabled};

    return @clients;
}

=head2 clients_for_landing_company

get clients given special landing company short name.
    $user->clients_for_landing_company('svg');

=cut

sub clients_for_landing_company {
    my $self      = shift;
    my $lc_short  = shift // die 'need landing_company';
    my @login_ids = $self->bom_loginids;
    return map { $self->get_client_using_replica($_) }
        grep { LandingCompany::Registry->get_by_loginid($_)->short eq $lc_short } @login_ids;
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
    return grep { $_ !~ MT5_REGEX } $self->loginids;
}

=head2 bom_real_loginids

get non-mt5 real login ids

=cut

sub bom_real_loginids {
    my $self = shift;
    return grep { $_ !~ MT5_REGEX && $_ !~ VIRTUAL_REGEX } $self->loginids;
}

=head2 bom_virtual_loginid

get non-mt5 virtual login id

=cut

sub bom_virtual_loginid {
    my $self = shift;
    return first { $_ =~ VIRTUAL_REGEX } $self->loginids;
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
        my $group = BOM::MT5::User::Async::get_user($login)->else(sub { Future->done({}); })->get->{group} // '';

        $mt5_logins_with_group->{$login} = $group if (not $filter or $group =~ /^$filter/);
    }

    return $mt5_logins_with_group;
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

    my @all_mt5_loginids = $self->get_mt5_loginids;
    # We want to check the real mt5 accounts, so we filter out MTD, then reverse sort,
    # that will move MTR first, and latest created id first
    my @loginids = reverse sort grep { !/^MTD\d+/ } @all_mt5_loginids;
    for my $loginid (@loginids) {
        my $group = BOM::MT5::User::Async::get_user($loginid)->else(sub { Future->done({}) })->get->{group};
        # TODO (JB): to remove old group mapping once all accounts are moved to new group
        return 1 if (defined($group) && ($group =~ /^(?!demo)[a-z]+\\(?!svg)[a-z]+(?:_financial)/ || $group =~ /^real(?:01|02)\\financial\\(?!svg)/));
    }

    return 0;
}

=head2 get_clients_in_sorted_order

Return an ARRAY reference that is a list of clients in following order

- real enabled accounts (fiat first, then crypto)
- virtual accounts
- self excluded accounts
- disabled accounts

=cut

sub get_clients_in_sorted_order {
    my ($self, %args) = @_;
    my $include_duplicated = $args{include_duplicated} // 0;
    my $account_lists      = $self->accounts_by_category([$self->bom_loginids], include_duplicated => $include_duplicated);
    my @allowed_statuses   = qw(enabled virtual self_excluded disabled);
    push @allowed_statuses, 'duplicated' if ($include_duplicated);

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

=cut

sub accounts_by_category {
    my ($self, $loginid_list, %args) = @_;

    my (@enabled_accounts_fiat, @enabled_accounts_crypto, @virtual_accounts, @self_excluded_accounts, @disabled_accounts, @duplicated_accounts);
    foreach my $loginid (sort @$loginid_list) {
        my $cl = $self->get_client_using_replica($loginid);
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
    my $include_duplicated = $args{include_duplicated} // 0;

    return $self->{_default_client_include_disabled} if exists($self->{_default_client_include_disabled}) && $args{include_disabled};
    return $self->{_default_client_without_disabled} if exists($self->{_default_client_without_disabled}) && !$args{include_disabled};

    my $client_lists = $self->accounts_by_category([$self->bom_loginids], include_duplicated => $include_duplicated);
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
    return $self->dbic->run(
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
    my ($self,            %args)       = @_;
    my ($is_totp_enabled, $secret_key) = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array('select * from users.update_totp_fields(?, ?, ?)', undef, $self->{id}, $args{is_totp_enabled}, $args{secret_key});
        });
    $self->{is_totp_enabled} = $is_totp_enabled;
    $self->{secret_key}      = $secret_key;
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

sub get_mt5_loginids {
    my $self = shift;
    return (sort grep { $_ =~ MT5_REGEX } $self->loginids);
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
        if (!$attempt_known) {
            # for backward compatibility with users who never changed their login.
            my $last_attempt_in_db = $self->get_last_successful_login_history();
            if (!$last_attempt_in_db) {
                $attempt_known = 1;
                return;
            }

            my $last_attempt_entry = BOM::User::Utility::login_details_identifier($last_attempt_in_db->{environment});
            $attempt_known = 1 if $last_attempt_entry eq $entry;
        }
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

    return $result->{ck_user_valid_to_anonymize};
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
        $cl = BOM::User::Client->new({
            loginid      => $login_id,
            db_operation => 'replica'
        });
    } catch ($e) {
        $log->warnf("Error getting replica connection: %s", $e);
        $error = $e;
    }

    # try master if replica is down
    $cl = BOM::User::Client->new({loginid => $login_id}) if not $cl or $error;

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

1;
