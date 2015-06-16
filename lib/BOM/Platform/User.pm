package BOM::Platform::User;

use strict;
use warnings;

use List::MoreUtils qw( uniq any );
use Email::Valid;
use DataDog::DogStatsd::Helper qw(stats_inc);
use BOM::Database::UserDB;
use BOM::Database::AutoGenerated::Rose::Users::Loginid;
use BOM::Database::AutoGenerated::Rose::Users::LoginHistory;
use BOM::System::Password;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request localize);
use base 'BOM::Database::AutoGenerated::Rose::Users::BinaryUser';
use BOM::System::AuditLog;

sub new {
    my $class = shift;
    my $args = shift || die 'BOM::Platform::User->new called without args';
    die "no email" unless $args->{email};

    my $identity = $args->{email};
    my $is_loginid;
    $is_loginid = 1 if (uc($identity) =~ /^[A-Z]{2,6}\d{4,}$/);

    if (not Email::Valid->address(lc $identity) and not $is_loginid) {
        die "wrong email or loginid format";
    }

    my $db = BOM::Database::UserDB::rose_db();
    my $self;
    if (not $is_loginid) {
        $self = $class->SUPER::new(
            email => lc $identity,
            db    => $db
        );
        $self->load(speculative => 1);
    } else {
        # supports login with loginid too, besides email
        my $loginid = BOM::Database::AutoGenerated::Rose::Users::Loginid->new(
            loginid => uc $identity,
            db      => $db,
        );
        if ($loginid->load) {
            $self = $loginid->binary_user;
            bless $self, 'BOM::Platform::User';
        }
    }
    return $self;
}

=head2 $class->login(%args)

Check user credentials. Requires password as argument.
Returns hashref, {success => 1} if successfully authenticated user or {error => 'failed reason'} otherwise.

=cut

sub login {
    my ($self, %args) = @_;
    die "requires password argument" unless $args{password};
    my $password = $args{password};
    my $environment = $args{environment} || '';

    unless ($self->id and $self->password) {
        BOM::System::AuditLog::log('Invalid user login', $self->email);
        return {error => 'Incorrect email or password.'};
    }

    my ($error, $cfl);
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

    $cfl->delete if $cfl;    # delete the entry as we don't want to store it
    BOM::System::AuditLog::log('successful login', $self->email);
    stats_inc("business.log_in.success");
    return {success => 1};
}

sub loginid_array {
    my $self         = shift;
    my @rose_loginid = $self->loginid;

    my @codes = BOM::Platform::Runtime->instance->broker_codes->all_codes;
    my @loginids;
    foreach (@rose_loginid) {
        my $loginid = $_->loginid;

        my $broker;
        $loginid =~ /^(\D+)\d+$/ and $broker = $1;

        if ($broker and (any { $broker eq $_ } @codes)) {
            push @loginids, $loginid;
        }
    }
    return @loginids;
}

sub get_client_info {
    my $self = shift;

    my @loginids = $self->loginid_array;
    my @brokers = uniq map { /^(\D+)\d+$/ ? my $x = $1 : () } @loginids;

    my $client_info = {};
    foreach my $broker (@brokers) {
        my $real = 1;
        if (BOM::Platform::Runtime->instance->broker_codes->get($broker)->is_virtual) {
            $real = 0;
        }

        # query client db to get disabled status
        my $dbh = BOM::Database::ClientDB->new({
                broker_code => $broker,
                operation   => 'replica',
            })->db->dbh;

        my $sql = q{
            SELECT loginid, broker_code, COALESCE(status_code, '') as status
            FROM betonmarkets.client c
            LEFT JOIN betonmarkets.client_status s
                ON c.loginid = s.client_loginid
                AND status_code = 'disabled'
            WHERE c.email = ?
        };

        my $select_sth = $dbh->prepare($sql);
        $select_sth->execute($self->email);

        while (my $result = $select_sth->fetchrow_arrayref()) {
            my $loginid     = $result->[0];
            my $broker_code = $result->[1];
            my $status      = $result->[2];

            next if ($broker_code ne $broker);

            my $info;
            if ($status eq 'disabled') {
                $info->{disabled} = 1;
            } else {
                $info->{disabled} = 0;
            }

            $info->{real} = $real;
            $client_info->{$loginid} = $info;
        }
    }
    return $client_info;
}

sub cookie_and_default_loginid {
    my $self        = shift;
    my $client_info = $self->get_client_info();

    my @clients;
    my ($default, $vr_default);
    foreach my $loginid (sort keys %{$client_info}) {
        my $client = $client_info->{$loginid};

        # default loginid
        if (not $default and $client->{real} == 1 and $client->{disabled} == 0) {
            $default = $loginid;
        }
        if (not $vr_default and $client->{real} == 0 and $client->{disabled} == 0) {
            $vr_default = $loginid;
        }

        # cookie string
        if ($client->{real} == 1) {
            $loginid .= ':R';
        } else {
            $loginid .= ':V';
        }

        if ($client->{disabled} == 1) {
            $loginid .= ':D';
        } else {
            $loginid .= ':E';
        }
        push @clients, $loginid;
    }

    if (not $default and $vr_default) {
        $default = $vr_default;
    }

    my $cookie_str = join('+', @clients);

    return {
        cookie  => $cookie_str,
        loginid => $default,
        virtual => $vr_default
    };
}

1;
