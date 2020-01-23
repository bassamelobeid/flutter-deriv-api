package BOM::MT5::User::Async;

use strict;
use warnings;
no indirect;

use JSON;
use IPC::Run3;
use Syntax::Keyword::Try;
use Data::UUID;
use Time::HiRes;
use DataDog::DogStatsd::Helper;
use IO::Async::Loop;
# Overrideable in unit tests
our @MT5_WRAPPER_COMMAND = ('/usr/bin/php', '/home/git/regentmarkets/php-mt5-webapi/lib/binary_mt5.php');

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

# Note: API returns 3006 for ret_code on two API calls,
# 1. In mt5_new_account when presented main password formatting is wrong
# 2. In mt5_check_password when combination of presented username and password is not correct
# So we have to specify two different keys for this situations.
my $error_category_mapping = {
    3                          => 'InvalidParameters',
    7                          => 'NetworkError',
    8                          => 'Permissions',
    9                          => 'ConnectionTimeout',
    10                         => 'NoConnection',
    12                         => 'TooManyRequests',
    13                         => 'NotFound',
    1002                       => 'AccountDisabled',
    3006 . "UserPasswordCheck" => 'InvalidPassword',
    3006 . "UserAdd"           => 'IncorrectMT5PasswordFormat',
    10019                      => 'NoMoney'
};

my $FAILCOUNT_KEY     = 'system.mt5.connection_fail_count';
my $LOCK_KEY          = 'system.mt5.connection_status';
my $TRIAL_FLAG        = 'system.mt5.connection_check';
my $BACKOFF_THRESHOLD = 20;
my $BACKOFF_TTL       = 60;

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
    return (@common_fields, qw/login rights agent/);
}

sub _invoke_mt5 {
    my ($cmd, $param) = @_;

    my $in = encode_json($param);

    # IO::Async keeps this around as a singleton, so it's safe to call ->new, and
    # better than tracking in a local `state` variable since if we happen to fork
    # then we can trust the other IO::Async users to take care of clearing the
    # previous singleton.
    my $loop          = IO::Async::Loop->new;
    my $f             = $loop->new_future;
    my $request_start = [Time::HiRes::gettimeofday];
    my $redis         = BOM::Config::RedisReplicated::redis_mt5_user_write();
    my $failcount     = $redis->get($FAILCOUNT_KEY) // 0;
    my $lock          = $redis->get($LOCK_KEY) // 0;
    my $trying        = 0;
    # Backoff if we have tried 20 without being able to connect.
    if ($failcount >= $BACKOFF_THRESHOLD) {
        $redis->set($LOCK_KEY, 1);
        DataDog::DogStatsd::Helper::stats_inc('mt5.call.blocked', {tags => ["mt5:$cmd"]});
        return $f->fail(
            _future_error({
                    ret_code => 10,
                    error    => "no connection"
                }));
    } elsif ($lock) {
        my $is_worker_checking = $redis->get($TRIAL_FLAG) // 0;
        if ($is_worker_checking) {
            DataDog::DogStatsd::Helper::stats_inc('mt5.call.blocked', {tags => ["mt5:$cmd"]});
            return $f->fail(
                _future_error({
                        ret_code => 10,
                        error    => "no connection"
                    }));
        } else {
            # Set trial flag, so only one worker checks if we are able to connect.
            # Make sure flag has TTL so its removed in case worker dies mid call.
            my $flag_set = $redis->set(
                $TRIAL_FLAG => 1,
                EX          => 30,
                "NX"
            ) // 0;
            # in case Flag was already set, we will get 0 so prevent call since a worker already trying to.
            unless ($flag_set) {
                DataDog::DogStatsd::Helper::stats_inc('mt5.call.blocked', {tags => ["mt5:$cmd"]});
                return $f->fail(
                    _future_error({
                            ret_code => 10,
                            error    => "no connection"
                        }));
            }
            $trying = 1;
        }
    }
    $loop->run_child(
        command   => [@MT5_WRAPPER_COMMAND, $cmd],
        stdin     => $in,
        on_finish => sub {
            my (undef, $exitcode, $out, $err) = @_;
            warn "MT5 PHP call nonzero status: $exitcode\n" if $exitcode;
            warn "MT5 PHP call error: $err from $in\n" if defined($err) && length($err);

            DataDog::DogStatsd::Helper::stats_timing('mt5.call.timing', (1000 * Time::HiRes::tv_interval($request_start)), {tags => ["mt5:$cmd"]});

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
                    # Update connection trials counter in Redis, with 1 minute TTL
                    # code 10 is 'no connection' & 9 'connection timeout'
                    if ($out->{ret_code} == 10 || $out->{ret_code} == 9) {
                        DataDog::DogStatsd::Helper::stats_inc('mt5.call.connection_fail');
                        if ($lock) {
                            # If our last try was failed also, set key to threshold straight away.
                            $redis->setex($FAILCOUNT_KEY, $BACKOFF_TTL, $BACKOFF_THRESHOLD);
                        } else {
                            $redis->incr($FAILCOUNT_KEY);
                            $redis->expire($FAILCOUNT_KEY, $BACKOFF_TTL);
                        }
                    }
                    # needed as both of them return same code for different reason.
                    if (($cmd eq 'UserAdd' or $cmd eq 'UserPasswordCheck') and $out->{ret_code} == 3006) {
                        $out->{ret_code} .= $cmd;
                    }
                    $f->fail(_future_error($out));
                } else {
                    # Unset Lock since we got a success call.
                    $redis->set($LOCK_KEY, 0) if $lock;
                    $f->done($out);
                }
            }
            catch {
                my $e = $@;
                chomp $e;
                $f->fail($e, mt5 => $cmd);
            }
            $redis->del($TRIAL_FLAG) if $trying;

        },
    );

    return $f;
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
