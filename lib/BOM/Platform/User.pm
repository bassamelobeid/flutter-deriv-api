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

    my ($error, $cfl, @clients, @self_excluded);
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
    } elsif (
        @self_excluded = grep {
            $_->get_self_exclusion_until_dt
        } @clients
        and @self_excluded == @clients
        )
    {
        # If all accounts are self excluded - show error
        # Print the earliest time until user has excluded himself
        my ($client) = sort {
            my $tmp_a = $a->get_self_exclusion_until_dt;
            $tmp_a =~ s/GMT$//;
            my $tmp_b = $b->get_self_exclusion_until_dt;
            $tmp_b =~ s/GMT$//;
            Date::Utility->new($tmp_a)->epoch <=> Date::Utility->new($tmp_b)->epoch
        } @self_excluded;
        $error = localize('Sorry, you have excluded yourself until [_1].', $client->get_self_exclusion_until_dt);
        BOM::Platform::AuditLog::log('Account self excluded', $self->email);
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

    if (@self_excluded > 0) {
        my %excluded = map { $_->loginid => 1 } @self_excluded;
        $success->{self_excluded} = \%excluded;
    }

    return $success;
}

# Get my enabled client objects, in loginid order but with reals up first.  Use the replica db for speed.
# if called as $user->clients(disabled_ok=>1); will include disableds.
sub clients {
    my ($self, %args) = @_;

    # filter out non binary's loginid, eg: MT5 login
    my @bom_loginids = grep { $_->loginid !~ /^MT\d+$/ } $self->loginid;

    my @bom_clients = sort { (($a->is_virtual ? 'V' : 'R') . $a->loginid) cmp(($b->is_virtual ? 'V' : 'R') . $b->loginid) }
        map { Client::Account->new({loginid => $_->loginid, db_operation => 'replica'}) } @bom_loginids;

    my $all_status = Client::Account::client_status_types();
    my @do_not_display_status = grep { $all_status->{$_} == 0 } keys %$all_status;

    my @parts   = ();
    my @clients = ();
    foreach my $cl (@bom_clients) {
        # don't include clients that we don't want to show
        next if grep { $cl->get_status($_) } @do_not_display_status;

        my $is_disabled = $cl->get_status('disabled');
        push @parts, join(':', $cl->loginid, $cl->is_virtual ? 'V' : 'R', $is_disabled ? 'D' : 'E', $cl->get_status('ico_only') ? 'I' : 'N');

        next if (not $args{disabled_ok} and $is_disabled);

        push @clients, $cl;
    }

    $self->{_cookie_val} = join('+', @parts);

    return @clients;
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

1;
