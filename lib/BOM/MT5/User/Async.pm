package BOM::MT5::User::Async;

use strict;
use warnings;
no indirect;

use feature qw(state);

use JSON::MaybeXS;
use IPC::Run3;
use Syntax::Keyword::Try;
use Data::UUID;
use Time::HiRes;
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);
use IO::Async::Loop;
use Net::Async::HTTP;
use Log::Any qw($log);
use YAML::XS qw(LoadFile);
use Locale::Country qw(country2code);
use Future;
use Scalar::Util qw(blessed);

use BOM::MT5::Utility::CircuitBreaker;
use BOM::Config::Runtime;
use BOM::Config;

=head1 NAME 

BOM::MT5::User::Async - Async Wrapper for MT5 calls.

=head1 SYNOPSIS 

    BOM::MT5::User::Async::get_user ('12341234')->get();
    BOM::MT5::User::Async::get_user('12341234')->then(sub {...});
    await BOM::MT5::User::Async::get_user('12341234'); #if L<Future::AsyncAwait> is used


=head1 DESCRIPTION 

Provides async wrappers for specific MT5 calls, it can use php based wrapper or
a more modern http proxy to make request to MT5.

=cut

# Overrideable in unit tests
our @MT5_WRAPPER_COMMAND = ('/usr/bin/php', '/home/git/regentmarkets/php-mt5-webapi/lib/binary_mt5.php');

# Register new users in this server by default
our $DEFAULT_TRADING_SERVER_KEY = '01';

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

my $MAIN_TRADING_SERVER_KEY = 'p01_ts01';

# Mapping from trade server name to BOM::MT5::Utility::CircuitBreaker instances
my $circuit_breaker_cache = {};

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

=head2 _get_server_type_by_prefix

Method detects server type by prefix.

=cut

sub _get_server_type_by_prefix {
    my $prefix = shift;

    return 'real' if $prefix eq 'MT' || $prefix eq 'MTR';

    return 'demo' if $prefix eq 'MTD';

    die "Unexpected prefix $prefix";
}

=head2 get_trading_server_key

Returns key of trading server which the request should be sent to

MT5 requests will be routed to different trading servers. Before a request get passed to
the PHP script, this method detects the destination of request based on: 

=over 4

=item * login ranges

=item * group name suffix

=back

Takes the following parameters:

=over 4

=item * C<$param> - hashref representing the request parameters that are going to be sent to MT5 server. For C<create_user>, C<get_groups> and C<get_user_logins> we expect having a defined $param->{group}, and for all other requests we expect $param->{login} to be defined.

=item * C<$srv_type> - string representing type of the MT5 sevrer (demo/real)

=back 

Returns a string (key of the trading server).

=cut

sub get_trading_server_key {
    my ($param, $srv_type) = @_;
    my $config = BOM::Config::mt5_webapi_config();

    if ($param->{login}) {
        my ($login_id) = $param->{login} =~ /([0-9]+)/;
        for my $server_key (keys $config->{$srv_type}->%*) {
            my @accounts_ranges = $config->{$srv_type}->{$server_key}->{accounts}->@*;
            for (@accounts_ranges) {
                return $server_key if ($login_id >= $_->{from} and $login_id <= $_->{to});
            }
        }

        # if the login is not in any range (probably mt5webapi.yml is outdated)
        die "Unexpected login (not in range) $param->{login}";
    }

    if ($param->{group}) {
        for my $server_key (keys $config->{$srv_type}->%*) {
            return $server_key if ($param->{group} =~ /^$srv_type\\$server_key\\.*$/);
        }
    }

    # if there is no suffix on group name it is Main Trading Server
    return $MAIN_TRADING_SERVER_KEY;
}

=head2 _get_prefix

Method extracts loginid prefix from request params.

=cut

sub _get_prefix {
    my ($param) = @_;

    if ($param->{login}) {
        return 'MT'  if $param->{login} =~ /^MT\d+$/;
        return 'MTR' if $param->{login} =~ /^MTR\d+$/;
        return 'MTD' if $param->{login} =~ /^MTD\d+$/;

        die "Unexpected login id format $param->{login}";
    }

    if ($param->{group}) {
        return 'MTR' if $param->{group} =~ /^real/;
        return 'MTD' if $param->{group} =~ /^demo/;

        die "Unexpected group format $param->{group}";
    }

    die "Unexpected request params: " . join q{, } => keys %$param;

}

=head2 _prepare_params

Method prepares params for sending to mt5 server.
It removes login id prefixes form login and agent fields

=cut

sub _prepare_params {
    my %param = @_;

    $param{$_} && $param{$_} =~ s/^MT[DR]?// for (qw(login agent));

    return \%param;
}

=head2 is_suspended

Test whether the current cmd is suspended

=over 4

=item * C<cmd>

=item * C<param> - the param of cmd. Used to tell it is deposit or withdrawal when cmd is  C<UserDepositChange>

=back

Returns the code string if suspended, C<undef> otherwise.

=cut

# The error code here is extracted from BOM::RPC::v3::MT5::Errors
sub is_suspended {
    my ($cmd, $param) = @_;

    my $suspend = BOM::Config::Runtime->instance->app_config->system->mt5->suspend;
    return 'MT5APISuspendedError' if $suspend->all;

    my $srv_type   = _get_server_type_by_prefix(_get_prefix($param));
    my $server_key = get_trading_server_key($param, $srv_type);

    if ($suspend->$srv_type->$server_key->all) {
        return $srv_type eq 'demo' ? 'MT5DEMOAPISuspendedError' : 'MT5REALAPISuspendedError';
    }

    return undef if $cmd ne 'UserDepositChange';
    return undef if $srv_type eq 'demo';

    if ($param->{new_deposit} > 0) {
        return 'MT5REALDepositSuspended'
            if $suspend->deposits
            or ($suspend->$srv_type->$server_key->can('deposits') and $suspend->$srv_type->$server_key->deposits);
    } else {
        return 'MT5REALWithdrawalSuspended'
            if $suspend->withdrawals
            or ($suspend->$srv_type->$server_key->can('withdrawals') and $suspend->$srv_type->$server_key->withdrawals);
    }

    return undef;
}

=head2 _invoke_mt5

Call MT5 API if the requests to the MT5 server are allowed or return a failure future with connection error.

=over 4

=item * C<cmd> - MT5 cmd

=item * C<param> - The params in hashref used by cmd

=back

Returns Future object. Future object will be done if succeed, fail otherwise.

=cut

sub _invoke_mt5 {
    my ($cmd, $param) = @_;
    if (my $suspended_code = is_suspended($cmd, $param)) {
        return Future->fail(
            _future_error({
                    code => $suspended_code,
                }));
    }

    my ($srv_type, $prefix, $srv_key);
    try {
        $prefix   = _get_prefix($param);
        $srv_type = _get_server_type_by_prefix($prefix);
        $srv_key  = get_trading_server_key($param, $srv_type);
    } catch ($e) {
        $log->infof('Error in proccessing mt5 request: %s', $e);
        return Future->fail(_future_error({code => 'General'}));
    }

    my $dd_tags             = ["mt5:$cmd", "server_type:$srv_type", "server_code:$srv_key"];
    my $circuit_breaker_key = $srv_type . "_" . $srv_key;
    my $circuit_breaker     = do {
        $circuit_breaker_cache->{$circuit_breaker_key} //= BOM::MT5::Utility::CircuitBreaker->new(
            server_type => $srv_type,
            server_code => $srv_key
        );
    };

    my $request_state = $circuit_breaker->request_state();
    unless ($request_state->{allowed}) {
        stats_inc('mt5.call.blocked', {tags => $dd_tags});
        return Future->fail(_future_error({ret_code => 10}));
    }

    stats_inc('mt5.call.test_request', {tags => $dd_tags}) if $request_state->{testing};

    return _invoke($cmd, $srv_type, $srv_key, $prefix, $param)->on_ready(
        sub {
            my $f = shift;
            $circuit_breaker->circuit_reset() if $f->is_done;

            if ($f->is_failed && (ref $f->failure eq "HASH")) {
                my $error_code = $f->failure->{code} // '';
                if ($error_code eq $error_category_mapping->{9} || $error_code eq $error_category_mapping->{10}) {
                    stats_inc('mt5.call.connection_fail', {tags => $dd_tags});
                    $circuit_breaker->record_failure();
                }
            }
        });
}

=head2  _is_http_proxy_enabled_for

Verify if the http proxy is enabled for the given server type and server key.

It expects:

=over 4

=item * C<$srv_type> - A string with the server type, e.g. 'demo', 'real'.

=item * C<$srv_key> - A string with the server key, e.g 'p01_ts01'.

=back 

returns 0 for disabled or any other value for enabled  

=cut 

sub _is_http_proxy_enabled_for {
    my ($srv_type, $srv_key) = @_;
    try {
        my $app_config = BOM::Config::Runtime->instance->app_config;

        return $app_config->system->mt5->http_proxy->$srv_type->$srv_key || 0;
    } catch ($e) {
        $log->warn("Can't get HTTP proxy config for $srv_type and $srv_key. Error was: $e");
        return 0;
    }
}

=head2 _is_parallel_run_enabled

Returns the status of parallel_run config for MT5 Proxy if it exists.

In case there is no config, the default is 0 (disabled).

=cut

sub _is_parallel_run_enabled {
    try {
        my $config = BOM::Config::Runtime->instance->app_config;
        return $config->system->mt5->parallel_run || 0;
    } catch ($e) {
        return 0;
    }
}

=head2 _invoke

Call mt5 api and return result wrapped in C<Future> object

=over 4

=item * C<cmd>              - MT5 cmd. A string.  

=item * C<prefix>           - Login ID prefix. A string.

=item * C<srv_type>         - MT5 server type ('demo', 'real'). 

=item * C<srv_key>          - MT5 server code (e.g 'p01_ts01')

=item * C<param>            - The params in hashref used by cmd

=back

Returns Future object. Future object will be done if succeed, fail otherwise.

=cut

sub _invoke {
    my ($cmd, $srv_type, $srv_key, $prefix, $param) = @_;

    # IO::Async keeps this around as a singleton, so it's safe to call ->new, and
    # better than tracking in a local `state` variable since if we happen to fork
    # then we can trust the other IO::Async users to take care of clearing the
    # previous singleton.
    my $loop = IO::Async::Loop->new;

    my $mt5_proxy_usage_enabled = _is_http_proxy_enabled_for($srv_type, $srv_key);
    my $parallel_run            = _is_parallel_run_enabled;

    my %readonly_calls = (
        # These commented calls can cause cache invalidation issues in MT5 HTTP Proxy.
        # UserGet           => 1,
        # UserPasswordCheck => 1,
        PositionGetTotal => 1,
        GroupGet         => 1,
        UserLogins       => 1
    );

    if ($parallel_run) {
        if ($mt5_proxy_usage_enabled and exists $readonly_calls{$cmd}) {
            try {
                _invoke_using_proxy($cmd, $srv_type, $srv_key, $prefix, $param, $loop)->get;
            } catch ($e) {
                my $message = $e;
                if (blessed($e) && $e->isa('Future::Exception')) {
                    $message = "[" . $e->category . "] " . $e->message . ": " . $e->details;
                }
                $log->debugf('MT5 Proxy Error: %s', $message);
            }
        }
        return _invoke_using_php($cmd, $srv_type, $srv_key, $prefix, $param, $loop);
    } elsif ($mt5_proxy_usage_enabled) {
        return _invoke_using_proxy($cmd, $srv_type, $srv_key, $prefix, $param, $loop);
    } else {
        return _invoke_using_php($cmd, $srv_type, $srv_key, $prefix, $param, $loop);
    }
}

=head2 _invoke_using_proxy

Invokes MT5 command using the HTTP Proxy.

It expects a list of arguments same as L</_invoke> but with an additional C<$loop>
variable with an instance of L<IO::Async::Loop>.

It returns a L<Future> with the response of the invocation. 

=cut

sub _invoke_using_proxy {
    my ($cmd, $srv_type, $srv_key, $prefix, $param, $loop) = @_;

    my $dd_tags       = ["mt5:$cmd", "server_type:$srv_type", "server_code:$srv_key"];
    my $f             = $loop->new_future;
    my $request_start = [Time::HiRes::gettimeofday];
    my $http          = Net::Async::HTTP->new(
        decode_content => 1,
        fail_on_error  => 1,
        timeout        => 10,
    );
    $loop->add($http);

    if ($cmd eq "UserAdd") {
        $param->{pass_main}     = delete $param->{mainPassword};
        $param->{pass_investor} = delete $param->{investPassword};
    } elsif ($cmd eq "UserPasswordChange") {
        $param->{password} = delete $param->{new_password};
    }

    my $in            = encode_json(_prepare_params(%$param));
    my $config        = BOM::Config::mt5_webapi_config();
    my $mt5_proxy_url = $config->{mt5_http_proxy_url};

    my $result;
    my $url = $mt5_proxy_url . '/' . $srv_type . '_' . $srv_key . '/' . $cmd;
    $result = $http->POST($url, $in, content_type => 'application/json')->then(
        sub {
            my ($result) = @_;
            stats_inc('mt5.call.proxy.successful', {tags => $dd_tags});

            return $result;
        }
    )->else(
        sub {
            my $error = shift;
            stats_inc('mt5.call.proxy.request_error', {tags => $dd_tags});
            return $f->fail($error, mt5 => $cmd);
        }
    )->on_ready(
        sub {
            stats_timing('mt5.call.proxy.timing', (1000 * Time::HiRes::tv_interval($request_start)), {tags => $dd_tags});
        }
    )->then(
        sub {
            my $result = shift;

            my $out = $result->content;
            $out =~ s/[\x0D\x0A]//g;
            $out = decode_json($out);

            # Converting all keys down to 2nd level to lowercase in order to prevent case related key errors
            if (ref $out eq ref {}) {
                $out = {map { lc $_ => $out->{$_} } keys %$out};
                foreach my $key (keys %$out) {
                    if (ref $out->{$key} eq ref {}) {
                        $out->{$key} = {map { lc $_ => $out->{$key}->{$_} } keys %{$out->{$key}}};
                    }
                }
            }

            if ($out->{error}) {
                if ($out->{code} && !defined $out->{ret_code}) {
                    $out->{ret_code} = $out->{code};
                }
                # needed as both of them return same code for different reason.
                if (($cmd eq 'UserAdd' or $cmd eq 'UserPasswordCheck') and $out->{ret_code} == 3006) {
                    $out->{ret_code} .= $cmd;
                }
                stats_inc('mt5.call.proxy.error', {tags => $dd_tags});
                return $f->fail(_future_error($out));
            } else {
                if ($cmd eq "UserAdd") {
                    $out->{login} = $out->{user}->{login};
                } elsif ($cmd eq "UserGet") {
                    delete $out->{user}->{apidata};
                } elsif ($cmd eq "GroupGet") {
                    delete $out->{group}->{symbols};
                }

                # Append login prefixes for mt5 used id.
                if ($out->{user} && $out->{user}{login}) {
                    $out->{user}{login} = $prefix . $out->{user}{login};
                }

                if ($out->{login}) {
                    $out->{login} = $prefix . $out->{login};
                }

                return $f->done($out);
            }
        }
    )->else(
        sub {
            my $error = shift;

            return Future->fail($f->failure) if $f->is_failed;

            unless (ref $error eq 'HASH' && $error->{error}) {
                stats_inc('mt5.call.proxy.payload_handling_error', {tags => $dd_tags});
            }

            return $f->fail($error, mt5 => $cmd);
        })->retain;
}

=head2 _invoke_using_php

Invokes MT5 command using the PHP script.

Parameters and return values are the same as in L</_invoke_using_proxy>.

=cut

sub _invoke_using_php {
    my ($cmd, $srv_type, $srv_key, $prefix, $param, $loop) = @_;
    my $dd_tags       = ["mt5:$cmd", "server_type:$srv_type", "server_code:$srv_key"];
    my $f             = $loop->new_future;
    my $in            = encode_json(_prepare_params(%$param));
    my $request_start = [Time::HiRes::gettimeofday];

    my $process_pid = $loop->run_child(
        command   => [@MT5_WRAPPER_COMMAND, $cmd, $srv_type, $srv_key],
        stdin     => $in,
        on_finish => sub {
            my (undef, $exitcode, $out, $err) = @_;
            $log->errorf("MT5 PHP call error: %s from %s", $err, $in) if defined($err) && length($err);

            stats_timing('mt5.call.timing', (1000 * Time::HiRes::tv_interval($request_start)), {tags => $dd_tags});

            if ($exitcode) {
                stats_inc('mt5.call.php_nonzero_status', {tags => $dd_tags});
                $log->debugf("MT5 PHP call nonzero status: %s", $exitcode);

                return $f->fail(
                    "binary_mt5 exited non-zero status ($exitcode)",
                    mt5 => $cmd,
                    $err
                );
            }
            stats_inc('mt5.call.successful', {tags => $dd_tags});

            $out =~ s/[\x0D\x0A]//g;

            try {
                $out = decode_json($out);

                if ($out->{error}) {

                    # needed as both of them return same code for different reason.
                    if (($cmd eq 'UserAdd' or $cmd eq 'UserPasswordCheck') and $out->{ret_code} == 3006) {
                        $out->{ret_code} .= $cmd;
                    }
                    stats_inc('mt5.call.error', {tags => $dd_tags});
                    $f->fail(_future_error($out));

                } else {
                    # Append login prefixes for mt5 used id.
                    if ($out->{user} && $out->{user}{login}) {
                        $out->{user}{login} = $prefix . $out->{user}{login};
                    } elsif ($out->{login}) {
                        $out->{login} = $prefix . $out->{login};
                    }

                    $f->done($out);
                }
            } catch ($e) {
                stats_inc('mt5.call.payload_handling_error', {tags => $dd_tags});
                chomp $e;
                $f->fail($e, mt5 => $cmd);
            }
        },
    );

    my $process_timeout = BOM::Config::mt5_webapi_config()->{request_timeout} // 15;

    # Catch will be triggered whenever $f fails due to any reason
    # Or when timout reaches before PHP process respond. In this case we trigger connectionTimeout error
    #   and kill the PHP process which hasn't responded on time
    return Future->wait_any($f, $loop->timeout_future(after => $process_timeout))->catch(
        sub {
            my ($err) = @_;

            if ($err eq 'Timeout') {

                # Kill PHP process if timeout reaches before any response
                kill 9, $process_pid;
                return Future->fail(_future_error({ret_code => 9}));
            }

            return Future->fail($err);
        });
}

sub create_user {
    my $args = shift;

    my @fields = _get_create_user_fields();
    my $param  = {};
    $param->{$_} = $args->{$_} for (@fields);
    return _invoke_mt5('UserAdd', $param)->then(
        sub {
            my ($response) = @_;
            return Future->fail('Empty login returned from MT5 UserAdd') unless $response->{login};
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

=head2 get_user_archive

Gets MT5 archived users by invoking a 'UserArchiveGet' call

=over 4

=item * C<$loginid> MT5 login id

=back

returns fields from the _get_user_fields() subroutine

=cut

sub get_user_archive {
    my $login = shift;
    my $param = {login => $login};

    return _invoke_mt5('UserArchiveGet', $param)->then(
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

    # Due to the implementation of this module and the php-mt5-webapi repo
    #   you could only update the following properties. Failing to provide
    #   these data may lead to the reset of the missing prop on MT5.
    #   Look at the following codes for more information:
    #   https://github.com/regentmarkets/php-mt5-webapi/blob/master/lib/binary_mt5.php#L299-L328
    #   https://github.com/regentmarkets/php-mt5-webapi/blob/master/lib/mt5_api/mt5_user.php#L612-L636
    #
    #   address, agent, city, company, country, email, leverage,
    #   name, phone, phonePassword, rights, state, zipCode;

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

=head2 _future_error

Generates common error structure for MT5 related calls.

It expects a HASHREF with the following attributes.

=over 4

=item * C<code> - Optional STRING, describing the error code.

=item * C<ret_code> - Optinal STRING, describing the error code.

=item * C<error> - Optional STRING, an description providing more details about the error.

=back 

It returns a HASREF with the following attributes

=over 4

=item * C<code> - A STRING representing the error being throw.

=item * C<error> - A STRING with the details for the error.

=back

=cut

sub _future_error {
    my ($response) = @_;
    if ($response->{code} && _get_error_mapping($response->{code}) ne 'unknown') {
        $response->{ret_code} = $response->{code};
    }

    return {
        code  => $response->{ret_code} ? _get_error_mapping($response->{ret_code}) : $response->{code},
        error => $response->{error}};
}

=head2 get_account_type

Get the account type (real, demo) by login id.

=over 4

=item * C<loginid> - e.g. `MTR0000001`

=back

Returns a string with either 'demo' or 'real'

=cut

sub get_account_type {
    my ($loginid) = @_;
    my $prefix = _get_prefix({login => $loginid});
    return _get_server_type_by_prefix($prefix);
}

1;
