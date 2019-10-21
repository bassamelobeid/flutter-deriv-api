package BOM::MT5::User::Async;

use strict;
use warnings;
no indirect;

use JSON;
use IPC::Run3;
use Try::Tiny;
use BOM::MT5::User::Manager;
use Data::UUID;

use IO::Async::Loop;
# Overrideable in unit tests
our @MT5_WRAPPER_COMMAND = ('/usr/bin/php', '/home/git/regentmarkets/php-mt5-webapi/lib/binary_mt5.php');

my $manager;

my @common_fields = qw(
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

# the mapping from MT5 doc (need login)
# https://support.metaquotes.net/en/docs/mt5/api/reference_retcodes
my $error_category_mapping = {
    3     => 'InvalidParameters',
    7     => 'NetworkError',
    8     => 'Permissions',
    12    => 'TooManyRequests',
    13    => 'NotFound',
    1002  => 'AccountDisabled',
    3006  => 'InvalidPassword',
    10019 => 'NoMoney'
};

sub _get_error_mapping {
    my $error_code = shift;
    return $error_category_mapping->{$error_code} // 'unknown';
}

sub _get_create_user_fields {
    return (@common_fields, qw/mainPassword investPassword agent group/);
}

sub _get_user_fields {
    # last array is fields we don't send back to api as of now
    return (@common_fields, qw/login balance group/, qw/agent rights/);
}

sub _get_update_user_fields {
    return (@common_fields, qw/login rights/);
}

sub _get_mamm_update_user_fields {
    return (_get_update_user_fields(), qw/rights/);
}

sub _invoke_mt5 {
    my ($cmd, $param) = @_;

    my $in = encode_json($param);

    # IO::Async keeps this around as a singleton, so it's safe to call ->new, and
    # better than tracking in a local `state` variable since if we happen to fork
    # then we can trust the other IO::Async users to take care of clearing the
    # previous singleton.
    my $loop = IO::Async::Loop->new;
    my $f    = $loop->new_future;
    $loop->run_child(
        command   => [@MT5_WRAPPER_COMMAND, $cmd],
        stdin     => $in,
        on_finish => sub {
            my (undef, $exitcode, $out, $err) = @_;
            warn "MT5 PHP call nonzero status: $exitcode\n" if $exitcode;
            warn "MT5 PHP call error: $err from $in\n" if defined($err) && length($err);

            if ($exitcode) {
                return $f->fail(
                    "binary_mt5 exited non-zero status ($exitcode)",
                    mt5 => $cmd,
                    $err
                );
            }

            $out =~ s/[\x0D\x0A]//g;
            try {
                $out = decode_json($out);
                if ($out->{error}) {
                    $f->fail(_future_error($out));
                } else {
                    $f->done($out);
                }
            }
            catch {
                my $e = $_;
                chomp $e;
                $f->fail($e, mt5 => $cmd);
            };

        },
    );

    return $f;
}

sub _mt5_manager {
    return $manager if defined $manager;
    IO::Async::Loop->new->add($manager = BOM::MT5::User::Manager->new);
    return $manager;
}

sub create_user {
    my $args = shift;

    my @fields = _get_create_user_fields();
    my $param  = {};
    $param->{$_} = $args->{$_} for (@fields);

    return _invoke_mt5('UserAdd', $param)->then(
        sub {
            my ($response) = @_;
            return Future->done({login => $response->{login}});
        });
}

sub get_user {
    my $login = shift;
    my $param = {login => $login};

    return _invoke_mt5('UserGet', $param)->then(
        sub {
            my ($response) = @_;

            my $ret    = $response->{user};
            my @fields = _get_user_fields();

            my $mt_user;
            $mt_user->{$_} = $ret->{$_} for (@fields);
            return Future->done($mt_user);
        });
}

sub update_user {
    my $args   = shift;
    my @fields = _get_update_user_fields();

    my $param = {};
    $param->{$_} = $args->{$_} for (@fields);

    return _invoke_mt5('UserUpdate', $param)->then(
        sub {
            my ($response) = @_;

            my $ret = $response->{user};
            @fields = _get_user_fields();

            my $mt_user;
            $mt_user->{$_} = $ret->{$_} for (@fields);
            return Future->done($mt_user);
        });
}

sub update_mamm_user {
    my $args   = shift;
    my @fields = _get_mamm_update_user_fields();

    my $param = {};
    $param->{$_} = $args->{$_} for (@fields);

    return _invoke_mt5('UserUpdate', $param)->then(
        sub {
            my ($response) = @_;

            my $ret = $response->{user};
            @fields = _get_user_fields();

            my $mt_user;
            $mt_user->{$_} = $ret->{$_} for (@fields);
            return Future->done($mt_user);
        });
}

sub password_check {
    my $args  = shift;
    my $param = {
        login    => $args->{login},
        password => $args->{password},
        type     => $args->{type},
    };

    return _invoke_mt5('UserPasswordCheck', $param)->then(
        sub {

            return Future->done({status => 1});
        });
}

sub password_change {
    my $args  = shift;
    my $param = {
        login        => $args->{login},
        new_password => $args->{new_password},
        type         => $args->{type},
    };

    return _invoke_mt5('UserPasswordChange', $param)->then(
        sub {

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

    return _invoke_mt5('UserDepositChange', $param)->then(
        sub {

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

    return _invoke_mt5('UserDepositChange', $param)->then(
        sub {

            return Future->done({status => 1});
        });
}

sub manager_api_deposit {
    my $args = shift;
    return _mt5_manager->adjust_balance($args->{login}, $args->{amount}, $args->{comment})->then(
        sub {
            my ($response) = @_;

            if ($response->{success}) {
                return Future->done({status => 1});
            }

            return Future->done($response);
        }
        )->catch(
        sub {
            return Future->fail(
                _future_error({
                        code  => 'Timeout',
                        error => 'timeout'
                    }));
        });
}

sub manager_api_withdrawal {
    my $args   = shift;
    my $amount = $args->{amount};
    if ($amount >= 0) {
        warn "Amount should be < 0";
        return Future->fail(
            _future_error({
                    code  => 'InternalError',
                    error => 'internal error',
                }));
    }
    return _mt5_manager->adjust_balance($args->{login}, $amount, $args->{comment}, $args->{request_UUID})->then(
        sub {
            my ($response) = @_;

            if ($response->{success}) {
                return Future->done({status => 1});
            }

            return Future->done($response);
        }
        )->catch(
        sub {
            return Future->fail(
                _future_error({
                        code  => 'Timeout',
                        error => 'timeout'
                    }));
        });
}

sub get_open_positions_count {
    my $login = shift;

    return _invoke_mt5('PositionGetTotal', {login => $login})->then(
        sub {
            my ($response) = @_;

            return Future->done({total => $response->{total}});
        });
}

sub get_group {
    my $group_name = shift;

    return _invoke_mt5('GroupGet', {group => $group_name})->then(
        sub {
            my ($response) = @_;

            my $ret = $response->{group};
            return Future->done($ret);
        });
}

sub get_users_logins {
    my $group_name = shift;

    return _invoke_mt5('UserLogins', {group => $group_name})->then(
        sub {
            my ($response) = @_;

            my $ret = $response->{logins};
            return Future->done($ret);
        });
}

sub _future_error {
    my ($response) = @_;

    return {
        code => $response->{ret_code} ? _get_error_mapping($response->{ret_code}) : $response->{code},
        error => $response->{error}};
}

1;
