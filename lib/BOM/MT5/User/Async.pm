package BOM::MT5::User::Async;

use strict;
use warnings;
use JSON;
use IPC::Run3;

# We know we're running inside a Mojo app so this is best
use IO::Async::Loop::Mojo;

my $loop = IO::Async::Loop::Mojo->new;

sub __user_fields {
    my $action = shift;
    my @fields = qw(
        email
        name
        leverage
        address
        state
        city
        zipCode
        country
        company
        phone
        phonePassword
    );

    if ($action eq 'create_user') {
        push @fields, 'mainPassword', 'investPassword', 'agent';
    } else {
        push @fields, 'login';
    }

    if ($action eq 'get_user') {
        push @fields, 'balance';
    }
    if ($action ne 'update_user') {
        push @fields, 'group';
    }

    return @fields;
}

sub _invoke_mt5 {
    my ($cmd, $param) = @_;

    my $in = encode_json($param);

    my @cmd = ('php', '/home/git/regentmarkets/php-mt5-webapi/lib/binary_mt5.php', $cmd);

    # TODO(leonerd): This ought to be a method on IO::Async::Loop itself
    my $f = $loop->new_future;
    $loop->run_child(
        command => \@cmd,
        stdin => $in,
        on_finish => sub {
            my (undef, $exitcode, $out, $err) = @_;
            warn "MT5 PHP call nonzero status: $exitcode\n" if $exitcode;
            warn "MT5 PHP call error: $err from $in\n" if defined($err) && length($err);

            $out =~ s/[\x0D\x0A]//g;
            $f->done(decode_json($out));
        },
    );

    return $f;
}

sub create_user {
    my $args = shift;

    my @fields = __user_fields('create_user');
    my $param  = {};
    $param->{$_} = $args->{$_} for (@fields);

    return _invoke_mt5('UserAdd', $param)->then(sub {
        my ($hash) = @_;

        if ($hash->{error}) {
            return Future->done({error => $hash->{error}});
        }

        return Future->done({login => $hash->{login}});
    });
}

sub get_user {
    my $login = shift;
    my $param = {login => $login};

    return _invoke_mt5('UserGet', $param)->then(sub {
        my ($hash) = @_;

        if ($hash->{error}) {
            return Future->done({error => $hash->{error}});
        }

        my $ret    = $hash->{user};
        my @fields = __user_fields('get_user');

        my $mt_user;
        $mt_user->{$_} = $ret->{$_} for (@fields);
        return Future->done($mt_user);
    });
}

sub update_user {
    my $args   = shift;
    my @fields = __user_fields('update_user');

    my $param = {};
    $param->{$_} = $args->{$_} for (@fields);

    return _invoke_mt5('UserUpdate', $param)->then(sub {
        my ($hash) = @_;

        if ($hash->{error}) {
            return Future->done({error => $hash->{error}});
        }

        my $ret = $hash->{user};
        @fields = __user_fields('get_user');

        my $mt_user;
        $mt_user->{$_} = $ret->{$_} for (@fields);
        return Future->done($mt_user);
    });
}

sub password_check {
    my $args  = shift;
    my $param = {
        login    => $args->{login},
        password => $args->{password}};

    return _invoke_mt5('UserPasswordCheck', $param)->then(sub {
        my ($hash) = @_;

        if ($hash->{error}) {
            return Future->done({error => $hash->{error}});
        }
        return Future->done({status => 1});
    });
}

sub password_change {
    my $args  = shift;
    my $param = {
        login        => $args->{login},
        new_password => $args->{new_password}};

    return _invoke_mt5('UserPasswordChange', $param)->then(sub {
        my ($hash) = @_;

        if ($hash->{error}) {
            return Future->done({error => $hash->{error}});
        }
        return Future->done({status => 1});
    });
}

sub deposit {
    my $args  = shift;
    my $param = {
        login       => $args->{login},
        new_deposit => $args->{amount},
        comment     => $args->{comment},
        type        => '2'                 # enum DEAL_BALANCE = 2
    };

    return _invoke_mt5('UserDepositChange', $param)->then(sub {
        my ($hash) = @_;

        if ($hash->{error}) {
            return Future->done({error => $hash->{error}});
        }

        return Future->done({status => 1});
    });
}

sub withdrawal {
    my $args   = shift;
    my $amount = $args->{amount};
    $amount = -$amount if ($amount > 0);

    my $param = {
        login       => $args->{login},
        new_deposit => $amount,
        comment     => $args->{comment},
        type        => '2'                 # enum DEAL_BALANCE = 2
    };

    return _invoke_mt5('UserDepositChange', $param)->then( sub {
        my ($hash) = @_;

        if ($hash->{error}) {
            return Future->done({error => $hash->{error}});
        }

        return Future->done({status => 1});
    });
}

1;
