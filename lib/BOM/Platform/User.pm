package BOM::Platform::User;

use strict;
use warnings;

use Try::Tiny;
use Date::Utility;

use Client::Account;

use BOM::Database::UserDB;
use BOM::Platform::Password;
use BOM::Platform::AuditLog;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(localize);

use base 'BOM::Database::AutoGenerated::Rose::Users::BinaryUser';
use BOM::Database::AutoGenerated::Rose::Users::Loginid;

sub create {
    my $class = shift;
    return $class->SUPER::new(
        db => BOM::Database::UserDB::rose_db(),
        @_
    );
}

# support either email or id or loginid
sub new {
    my ($class, $args) = @_;
    die 'BOM::Platform::User->new called without args' unless $args;

    die "no email nor id or loginid" unless $args->{email} || $args->{id} || $args->{loginid};

    my $db = BOM::Database::UserDB::rose_db();

    # Lookup the given identity first as an email in BinaryUser then as a loginid in Loginid table.
    # the Rose 'new' interface does data-type checks for us and can raise exceptions.
    return try {
        my $self = BOM::Database::AutoGenerated::Rose::Users::BinaryUser->new(
            $args->{email} ? (email => lc $args->{email}) : (),
            $args->{id}    ? (id    => $args->{id})       : (),
            $args->{loginid}
            ? (
                id => BOM::Database::AutoGenerated::Rose::Users::Loginid->new(
                    loginid => $args->{loginid},
                    db      => $db,
                )->load()->binary_user_id
                )
            : (),
            db => $db,
        )->load(speculative => 1);
        bless $self, $class;
    }
    catch { undef };
}

=head2 $class->login(%args)

Check user credentials. Requires password as argument.
Returns hashref, {success => 1} if successfully authenticated user or {error => 'failed reason'} otherwise.

=cut

sub login {
    my ($self, %args) = @_;
    my $password        = $args{password}        || die "requires password argument";
    my $environment     = $args{environment}     || '';
    my $is_social_login = $args{is_social_login} || 0;

    my ($error, $cfl, @clients);
    if (BOM::Platform::Runtime->instance->app_config->system->suspend->all_logins) {
        $error = localize('Login to this account has been temporarily disabled due to system maintenance. Please try again in 30 minutes.');
        BOM::Platform::AuditLog::log('system suspend all login', $self->email);
    } elsif ($cfl = $self->failed_login and $cfl->fail_count > 5 and $cfl->last_attempt->epoch > time - 300) {
        $error = localize('Sorry, you have already had too many unsuccessful attempts. Please try again in 5 minutes.');
        BOM::Platform::AuditLog::log('failed login > 5 times', $self->email);
    } elsif (not $is_social_login and not BOM::Platform::Password::checkpw($password, $self->password)) {
        my $fail_count = $cfl ? $cfl->fail_count : 0;
        $self->failed_login({
            fail_count   => ++$fail_count,
            last_attempt => DateTime->now(),
        });
        $self->save;

        $error = localize('Incorrect email or password.');
        BOM::Platform::AuditLog::log('incorrect email or password', $self->email);
    } elsif (not @clients = $self->clients) {
        $error = localize('This account is unavailable.');
        BOM::Platform::AuditLog::log('Account disabled', $self->email);
    }

    $self->add_login_history({
        action      => 'login',
        environment => $environment,
        successful  => ($error) ? 'f' : 't'
    });
    $self->save;

    if ($error) {
        return {error => $error};
    }

    $cfl->delete if $cfl;    # delete client failed login
    BOM::Platform::AuditLog::log('successful login', $self->email);

    my $success = {success => 1};

    return $success;
}

# Get my enabled client objects, in loginid order but with reals up first.  Use the replica db for speed.
# if called as $user->clients(disabled_ok=>1); will include disableds.
sub clients {
    my ($self, %args) = @_;

    # filter out non binary's loginid, eg: MT5 login
    my @bom_loginids = map { $_->loginid } grep { $_->loginid !~ /^MT\d+$/ } $self->loginid;

    my @clients = @{$self->get_clients_in_sorted_order(\@bom_loginids, $args{disabled_ok})};

    my @parts;
    push @parts, _get_client_cookie_string($_) foreach (@clients);

    $self->{_cookie_val} = join('+', @parts);

    @clients = grep { not $_->get_status('disabled') } @clients unless $args{disabled_ok};

    return @clients;
}

sub _get_client_cookie_string {
    my $client = shift;

    my $str = join(':',
        $client->loginid,
        $client->is_virtual             ? 'V' : 'R',
        $client->get_status('disabled') ? 'D' : 'E',
        $client->get_status('ico_only') ? 'I' : 'N');

    return $str;
}

=head2 clients_for_landing_company

get clients given special landing company short name.
    $user->clients_for_landing_company('costarica');

=cut

sub clients_for_landing_company {
    my $self      = shift;
    my $lc_short  = shift // die 'need landing_company';
    my @login_ids = keys %{$self->loginid_details};
    return map { Client::Account->new({loginid => $_, db_operation => 'replica'}) }
        grep { LandingCompany::Registry->get_by_loginid($_)->short eq $lc_short } @login_ids;
}

sub loginid_details {
    my $self = shift;

    return {
        map { $_->loginid => {loginid => $_->loginid, broker_code => ($_->loginid =~ /(^[a-zA-Z]+)/)} }
        grep { $_->loginid !~ /^MT\d+$/ } $self->loginid
    };
}

sub mt5_logins {
    my $self = shift;
    my @mt5_logins = sort map { $_->loginid } grep { $_->loginid =~ /^MT\d+$/ } $self->loginid;
    return @mt5_logins;
}

sub loginid_list_cookie_val {
    my $self = shift;
    $self->{_cookie_val} || $self->clients;
    return $self->{_cookie_val};
}

sub get_last_successful_login_history {
    my $self = shift;

    my $last_login =
        $self->db->dbic->run(
        sub { $_->selectrow_hashref('SELECT environment, history_date FROM users.last_login WHERE binary_user_id = ?', undef, $self->{id}) });

    if ($last_login) {
        return {
            action      => 'login',
            status      => 1,
            environment => $last_login->{environment},
            epoch       => Date::Utility->new($last_login->{history_date})->epoch
        };
    }

    return;
}

=head2

Return list of client in following order

- real enabled accounts
- ico only accounts
- virtual accounts
- self excluded accounts
- disabled accounts

=cut

sub get_clients_in_sorted_order {
    my ($self, $loginid_list, $include_disabled) = @_;

    my (@enabled_accounts, @ico_accounts, @virtual_accounts, @self_excluded_accounts, @disabled_accounts);
    foreach my $loginid (sort @$loginid_list) {
        my $cl = try {
            Client::Account->new({
                loginid      => $loginid,
                db_operation => 'replica'
            });
        }
        catch {
            # try master if replica is down
            Client::Account->new({loginid => $loginid});
        };

        next unless $cl;

        my $all_status = Client::Account::client_status_types();
        my @do_not_display_status = grep { $all_status->{$_} == 0 } keys %$all_status;

        # don't include clients that we don't want to show
        next if grep { $cl->get_status($_) } @do_not_display_status;

        if ($cl->get_status('disabled')) {
            $self->{_real_client} = $cl if ($include_disabled and not $self->{_real_client});
            push @disabled_accounts, $cl;
            next;
        }

        if ($cl->get_self_exclusion_until_date) {
            push @self_excluded_accounts, $cl;
            next;
        }

        if ($cl->get_status('ico_only')) {
            $self->{_real_client} = $cl unless $self->{_real_client};
            push @ico_accounts, $cl;
            next;
        }

        if ($cl->is_virtual) {
            $self->{_virtual_client} = $cl unless $self->{_virtual_client};
            push @virtual_accounts, $cl;
            next;
        }

        $self->{_first_enabled_real_client} = $cl unless $self->{_first_enabled_real_client};
        push @enabled_accounts, $cl;
    }

    return [(@enabled_accounts, @ico_accounts, @virtual_accounts, @self_excluded_accounts, @disabled_accounts)];
}

=head2 get_default_client

Returns default client for particular user
Act as replacement for using "$siblings[0]" or "$clients[0]"

=cut

sub get_default_client {
    my $self = shift;

    return $self->{_first_enabled_real_client} // $self->{_real_client} // $self->{_virtual_client};
}

1;
