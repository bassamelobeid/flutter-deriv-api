package BOM::User;

use strict;
use warnings;

use feature 'state';
use Try::Tiny;
use Date::Utility;
use List::Util qw(first any);
use Scalar::Util qw(blessed looks_like_number);
use Carp qw(croak carp);

use BOM::MT5::User::Async;
use BOM::Database::UserDB;
use BOM::User::Password;
use BOM::User::AuditLog;
use BOM::User::Static;
use BOM::User::Utility;
use BOM::User::Client;
use BOM::User::Onfido;
use BOM::Config::Runtime;
use LandingCompany::Registry;
use Exporter qw( import );
our @EXPORT_OK = qw( is_payment_agents_suspended_in_country );

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
    MT5_REGEX     => qr/^MT[0-9]+$/,
    VIRTUAL_REGEX => qr/^VR/,
};

sub create {
    my ($class, %args) = @_;
    croak "email and password are mandatory" unless (exists($args{email}) && exists($args{password}));
    my @new_values = @args{@fields};
    shift @new_values;    #remove id value
    my $placeholders = join ",", ('?') x @new_values;
    my $sql          = "select * from users.create_user($placeholders)";
    my $result       = $class->dbic->run(
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
            $_->do('select users.record_login_history(?,?,?,?)', undef, $self->{id}, $error ? 'f' : 't', $log_as_failed, $environment);
        });
    return {error => $error_mapping->{$error}} if $error;

    # gamstop is applicable for UK residence only
    my $gamstop_client = first { $_->residence eq 'gb' and $_->landing_company->short =~ /^(?:malta|iom)$/ } @clients;
    BOM::User::Utility::set_gamstop_self_exclusion($gamstop_client) if $gamstop_client;
    return {success => 1};
}
#
# Get my enabled client objects, in loginid order but with reals up first.  Use the replica db for speed.
# if called as $user->clients(include_disabled=>1); will include disableds.
sub clients {
    my ($self, %args) = @_;

    my @clients = @{$self->get_clients_in_sorted_order};

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
    return map { BOM::User::Client->new({loginid => $_, db_operation => 'replica'}) }
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

#
sub mt5_logins {
    my $self = shift;
    my $filter = shift // 'real|demo';
    my @mt5_logins;

    for my $login (sort grep { $_ =~ MT5_REGEX } $self->loginids) {
        push(@mt5_logins, $login)
            if (
            not $filter or (
                BOM::MT5::User::Async::get_user(
                    do { $login =~ /(\d+)/; $1 }
                )->get->{group} // ''
            ) =~ /^$filter/
            );
    }

    return @mt5_logins;
}

sub get_last_successful_login_history {
    my $self = shift;

    return $self->dbic->run(fixup => sub { $_->selectrow_hashref('SELECT * FROM users.get_last_successful_login_history(?)', undef, $self->{id}) });
}

=head2 get_clients_in_sorted_order

Return an ARRAY reference that is a list of clients in following order

- real enabled accounts
- virtual accounts
- self excluded accounts
- disabled accounts

=cut

sub get_clients_in_sorted_order {
    my ($self) = @_;
    my $account_lists = $self->accounts_by_category([$self->bom_loginids]);

    return [map { @$_ } @{$account_lists}{qw(enabled virtual self_excluded disabled)}];
}

=head2 accounts_by_category

Given the loginid list, return the accounts grouped by the category in a HASH reference.
The categories are:

- real enabled accounts
- virtual accounts
- self excluded accounts
- disabled accounts

=cut

sub accounts_by_category {
    my ($self, $loginid_list) = @_;

    my (@enabled_accounts, @virtual_accounts, @self_excluded_accounts, @disabled_accounts);
    foreach my $loginid (sort @$loginid_list) {
        my $cl = try {
            BOM::User::Client->new({
                loginid      => $loginid,
                db_operation => 'replica'
            });
        }
        catch {
            # try master if replica is down
            BOM::User::Client->new({loginid => $loginid});
        };

        next unless $cl;

        next if $cl->status->is_login_disallowed;

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

        push @enabled_accounts, $cl;
    }

    return {
        enabled       => \@enabled_accounts,
        virtual       => \@virtual_accounts,
        self_excluded => \@self_excluded_accounts,
        disabled      => \@disabled_accounts
    };
}

=head2 get_default_client

Returns default client for particular user
Act as replacement for using "$siblings[0]" or "$clients[0]"

=cut

sub get_default_client {
    my ($self, %args) = @_;

    return $self->{_default_client_include_disabled} if exists($self->{_default_client_include_disabled}) && $args{include_disabled};
    return $self->{_default_client_without_disabled} if exists($self->{_default_client_without_disabled}) && !$args{include_disabled};

    my $client_lists = $self->accounts_by_category([$self->bom_loginids]);
    my %tmp;
    foreach my $k (keys %$client_lists) {
        $tmp{$k} = pop(@{$client_lists->{$k}});
    }
    $self->{_default_client_include_disabled} = $tmp{enabled} // $tmp{disabled} // $tmp{virtual} // $tmp{self_excluded};
    $self->{_default_client_without_disabled} = $tmp{enabled} // $tmp{virtual} // $tmp{self_excluded};
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
    my $sql = "select * from users.get_login_history(?,?) $limit";
    return $self->dbic->run(
        fixup => sub {
            $_->selectall_arrayref($sql, {Slice => {}}, $self->{id}, $args{order});
        });
}

sub add_login_history {
    my ($self, %args) = @_;
    $args{binary_user_id} = $self->{id};
    my @history_fields = qw(binary_user_id action environment successful ip country);
    my @new_values     = @args{@history_fields};

    my $placeholders = join ",", ('?') x @new_values;
    my $sql = "select * from users.add_login_history($placeholders)";
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
    return grep { $_ =~ MT5_REGEX } $self->loginids;
}

1;
