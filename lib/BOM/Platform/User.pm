## no critic (ProhibitReturnSort)
package BOM::Platform::User;

use strict;
use warnings;

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

sub new {
    my $class    = shift;
    my $args     = shift || die 'BOM::Platform::User->new called without args';
    my $identity = $args->{email} || die "no email";

    # Lookup the given identity first as an email in BinaryUser then as a loginid in Loginid table.
    # the Rose 'new' interface does data-type checks for us and can raise exceptions.
    my $self;
    try {
        my $db = BOM::Database::UserDB::rose_db();
        $self = BOM::Database::AutoGenerated::Rose::Users::BinaryUser->new(
            email => lc $identity,
            db    => $db
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
    my $password    = $args{password}    || die "requires password argument";
    my $environment = $args{environment} || '';

    my ($error, $cfl, @clients);
    if (BOM::Platform::Runtime->instance->app_config->system->suspend->all_logins) {

        $error = localize('Login to this account has been temporarily disabled due to system maintenance. Please try again in 30 minutes.');
        BOM::System::AuditLog::log('system suspend all login', $self->email);

    } elsif ($cfl = $self->failed_login and $cfl->fail_count > 5 and $cfl->last_attempt->epoch > time - 300) {

        $error = localize('Sorry, you have already had too many unsuccessful attempts. Please try again in 5 minutes.');
        BOM::System::AuditLog::log('failed login > 5 times', $self->email);

    } elsif (not BOM::System::Password::checkpw($args{password}, $self->password)) {

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
    }

    # If all accounts are self excluded - show error
    my @self_excluded = grep { $_->get_self_exclusion and $_->get_self_exclusion->exclude_until } @clients;
    if (@clients and @clients == @self_excluded) {
        # Print the earliest time until user has excluded himself
        my ($client) = sort {
            Date::Utility->new($a->get_self_exclusion->exclude_until)->epoch <=> Date::Utility->new($b->get_self_exclusion->exclude_until)->epoch
        } @self_excluded;
        $error = localize('Sorry, you have excluded yourself until [_1].', $client->get_self_exclusion->exclude_until);
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
    return {success => 1};
}

# Get my enabled client objects, in loginid order but with reals up first.  Use the replica db for speed.
# if called as $user->clients(disabled_ok=>1); will include disableds.
sub clients {
    my ($self, %args) = @_;

    my @all = sort { (($a->is_virtual ? 'V' : 'R') . $a->loginid) cmp(($b->is_virtual ? 'V' : 'R') . $b->loginid) }
        map { BOM::Platform::Client->new({loginid => $_, db_operation => 'replica'}) } $self->loginid;

    # generate the string needed by the loginid_list cookie (but remove the loginid_list cookie next!)
    my @parts = map { join ':', $_->loginid, $_->is_virtual ? 'V' : 'R', $_->get_status('disabled') ? 'D' : 'E' } @all;
    $self->{_cookie_val} = join('+', @parts);

    return grep { $args{disabled_ok} || !$_->get_status('disabled') } @all;
}

sub loginid_list_cookie_val {
    my $self = shift;
    $self->{_cookie_val} || $self->clients;
    return $self->{_cookie_val};
}

1;
