## no critic (ProhibitReturnSort)
package BOM::Platform::User;

use strict;
use warnings;

use Date::Utility;
use Try::Tiny;
use DataDog::DogStatsd::Helper qw(stats_inc);

use BOM::Database::UserDB;
use BOM::Database::AutoGenerated::Rose::Users::Loginid;
use BOM::System::Password;
use BOM::System::AuditLog;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request localize);
use BOM::Platform::Client;

use base 'BOM::Database::AutoGenerated::Rose::Users::BinaryUser';

sub create {
    my $class = shift;
    return $class->SUPER::new(
        db => BOM::Database::UserDB::rose_db(),
        @_
    );
}

# support either email or id
sub new {
    my $class = shift;
    my $args = shift || die 'BOM::Platform::User->new called without args';

    die "no email nor id" unless $args->{email} || $args->{id};

    # Lookup the given identity first as an email in BinaryUser then as a loginid in Loginid table.
    # the Rose 'new' interface does data-type checks for us and can raise exceptions.
    my $self;
    try {
        my $db = BOM::Database::UserDB::rose_db();
        $self = BOM::Database::AutoGenerated::Rose::Users::BinaryUser->new(
            $args->{email} ? (email => lc $args->{email}) : (),
            $args->{id}    ? (id    => $args->{id})       : (),
            db => $db
        )->load(speculative => 1);
        bless $self, 'BOM::Platform::User';
    }
    catch {};
    return $self;
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
        BOM::System::AuditLog::log('system suspend all login', $self->email);

    } elsif ($cfl = $self->failed_login and $cfl->fail_count > 5 and $cfl->last_attempt->epoch > time - 300) {

        $error = localize('Sorry, you have already had too many unsuccessful attempts. Please try again in 5 minutes.');
        BOM::System::AuditLog::log('failed login > 5 times', $self->email);

    } elsif (not $is_social_login and not BOM::System::Password::checkpw($args{password}, $self->password)) {

        my $fail_count = $cfl ? $cfl->fail_count : 0;
        $self->failed_login({
            fail_count   => ++$fail_count,
            last_attempt => DateTime->now(),
        });
        $self->save;

        $error = localize('Incorrect email or password.');
        BOM::System::AuditLog::log('incorrect email or password', $self->email);
    } elsif (not @clients = $self->clients) {
        $error = localize('This account is unavailable. For any questions please contact Customer Support.');
        BOM::System::AuditLog::log('Account disabled', $self->email);
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
        BOM::System::AuditLog::log('Account self excluded', $self->email);
    }

    $self->add_login_history({
        action      => 'login',
        environment => $environment,
        successful  => ($error) ? 'f' : 't'
    });
    $self->save;

    if ($error) {
        stats_inc("business.log_in.failure");
        return {error => $error};
    }

    $cfl->delete if $cfl;    # delete client failed login
    BOM::System::AuditLog::log('successful login', $self->email);
    stats_inc("business.log_in.success");

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
        map { BOM::Platform::Client->new({loginid => $_->loginid, db_operation => 'replica'}) } @bom_loginids;

    # generate the string needed by the loginid_list cookie (but remove the loginid_list cookie next!)
    my @parts = map { join ':', $_->loginid, $_->is_virtual ? 'V' : 'R', $_->get_status('disabled') ? 'D' : 'E' } @bom_clients;
    $self->{_cookie_val} = join('+', @parts);

    return grep { $args{disabled_ok} || !$_->get_status('disabled') } @bom_clients;
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

    my $login_history = $self->find_login_history(
        query => [
            action     => 'login',
            successful => 't'
        ],
        sort_by => 'history_date desc',
        limit   => 1
    );

    if (@{$login_history}) {
        my $record = @{$login_history}[0];
        return {
            action      => $record->action,
            status      => $record->successful ? 1 : 0,
            environment => $record->environment,
            epoch       => Date::Utility->new($record->history_date)->epoch
        };
    }

    return;
}

1;
