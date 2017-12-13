package BOM::MT5::User::Async;

use strict;
use warnings;
use JSON;
use IPC::Run3;

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

sub __php_call {
    my ($cmd, $param) = @_;

    my $in = encode_json($param);

    my @cmd = ('php', '/home/git/regentmarkets/php-mt5-webapi/lib/binary_mt5.php', $cmd);
    my ($out, $err);
    run3 \@cmd, \$in, \$out, \$err;

    warn "MT5 PHP call error: $err from $in\n" if defined($err) && length($err);
    $out =~ s/[\x0D\x0A]//g;
    return decode_json($out);
}

sub create_user {
    my $args = shift;

    my @fields = __user_fields('create_user');
    my $param  = {};
    $param->{$_} = $args->{$_} for (@fields);

    my $hash = __php_call('UserAdd', $param);

    if ($hash->{error}) {
        return {error => $hash->{error}};
    }

    return {login => $hash->{login}};
}

sub get_user {
    my $login = shift;
    my $param = {login => $login};

    my $hash = __php_call('UserGet', $param);

    if ($hash->{error}) {
        return {error => $hash->{error}};
    }

    my $ret    = $hash->{user};
    my @fields = __user_fields('get_user');

    my $mt_user;
    $mt_user->{$_} = $ret->{$_} for (@fields);
    return $mt_user;
}

sub update_user {
    my $args   = shift;
    my @fields = __user_fields('update_user');

    my $param = {};
    $param->{$_} = $args->{$_} for (@fields);

    my $hash = __php_call('UserUpdate', $param);

    if ($hash->{error}) {
        return {error => $hash->{error}};
    }

    my $ret = $hash->{user};
    @fields = __user_fields('get_user');

    my $mt_user;
    $mt_user->{$_} = $ret->{$_} for (@fields);
    return $mt_user;
}

sub password_check {
    my $args  = shift;
    my $param = {
        login    => $args->{login},
        password => $args->{password}};

    my $hash = __php_call('UserPasswordCheck', $param);

    if ($hash->{error}) {
        return {error => $hash->{error}};
    }
    return {status => 1};
}

sub password_change {
    my $args  = shift;
    my $param = {
        login        => $args->{login},
        new_password => $args->{new_password}};

    my $hash = __php_call('UserPasswordChange', $param);

    if ($hash->{error}) {
        return {error => $hash->{error}};
    }
    return {status => 1};
}

sub deposit {
    my $args  = shift;
    my $param = {
        login       => $args->{login},
        new_deposit => $args->{amount},
        comment     => $args->{comment},
        type        => '2'                 # enum DEAL_BALANCE = 2
    };

    my $hash = __php_call('UserDepositChange', $param);

    if ($hash->{error}) {
        return {error => $hash->{error}};
    }

    return {status => 1};
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

    my $hash = __php_call('UserDepositChange', $param);

    if ($hash->{error}) {
        return {error => $hash->{error}};
    }

    return {status => 1};
}

1;
