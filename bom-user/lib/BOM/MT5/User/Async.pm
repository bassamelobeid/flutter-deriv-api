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
use Log::Any        qw($log);
use YAML::XS        qw(LoadFile);
use Locale::Country qw(country2code);
use Future;
use Scalar::Util                                qw(blessed);
use BOM::TradingPlatform::Helper::HelperDerivEZ qw(is_derivez get_derivez_prefix set_deriv_prefix_to_mt5);

use BOM::MT5::Utility::CircuitBreaker;
use BOM::MT5::User::Cached;
use BOM::Config::Runtime;
use BOM::Config;
use HTTP::Tiny;
use Data::Dump qw(pp);

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

# HTTP request timeout in seconds
use constant HTTP_TIMEOUT_SECONDS => 10;

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
    comment
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
    11                         => 'ERR_NOSERVICE',
    12                         => 'TooManyRequests',
    13                         => 'NotFound',
    1002                       => 'AccountDisabled',
    3006 . "UserPasswordCheck" => 'InvalidPassword',
    3006 . "UserAdd"           => 'IncorrectMT5PasswordFormat',
    10019                      => 'NoMoney'
};

use constant MT5_ERROR_MESSAGE_CODE_MAPPING => {
    "Could not connect to 'localhost:80': Connection refused"        => "NoConnection",
    "Timed out while waiting for socket to become ready for reading" => "ConnectionTimeout"
};

my $MAIN_TRADING_SERVER_KEY = 'p01_ts01';

# Mapping from trade server name to BOM::MT5::Utility::CircuitBreaker instances
my $circuit_breaker_cache = {};

sub _get_error_mapping {
    my $error_code = shift;
    return $error_category_mapping->{$error_code} // 'unknown';
}

sub _get_create_user_fields {
    return (@common_fields, qw/mainPassword investPassword agent group rights platform/);
}

sub _get_user_fields {
    # last array is fields we don't send back to api as of now
    return (@common_fields, qw/login balance group color/, qw/agent rights/);
}

sub _get_archive_user_fields {
    return (@common_fields, qw/login balance group color agent rights comment lastaccess/);
}

sub _get_update_user_fields {
    return (@common_fields, qw/login rights agent color/);
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

        # We need to cater for derivez as the Server are using MT5
        if (is_derivez($param)) {
            return set_deriv_prefix_to_mt5($param);
        } else {
            return 'MT'  if $param->{login} =~ /^MT\d+$/;
            return 'MTR' if $param->{login} =~ /^MTR\d+$/;
            return 'MTD' if $param->{login} =~ /^MTD\d+$/;
        }

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

    # We need to cater for derivez as the Server are using MT5
    if (is_derivez({login => $param{login}})) {
        my $set_deriv_prefix_to_mt5 = set_deriv_prefix_to_mt5({login => $param{login}});
        my ($loginid_number) = $param{login} =~ /([0-9]+)/;
        $param{login} = $set_deriv_prefix_to_mt5 . $loginid_number;
    }
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

    # Setting up derivez prefix
    $prefix = get_derivez_prefix($param) if is_derivez($param);

    # Setting up datadog for derivez
    my $dd_tags;
    if (is_derivez($param)) {
        $dd_tags = ["derivez:$cmd", "server_type:$srv_type", "server_code:$srv_key"];
    } else {
        $dd_tags = ["mt5:$cmd", "server_type:$srv_type", "server_code:$srv_key"];
    }

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

            if ($f->is_failed && (ref $f->failure eq "HASH") && defined $f->failure->{code}) {
                my $error_code    = $f->failure->{code}  // '';
                my $error_message = $f->failure->{error} // '';

                if (   $error_code eq $error_category_mapping->{9}
                    || $error_code eq $error_category_mapping->{10}
                    || $error_message eq $error_category_mapping->{11}
                    || $error_message eq 'NonSuccessResponse')
                {
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

    # Setting up datadog for derivez
    my $dd_tags;
    if (is_derivez($param)) {
        $dd_tags = ["derivez:$cmd", "server_type:$srv_type", "server_code:$srv_key"];
    } else {
        $dd_tags = ["mt5:$cmd", "server_type:$srv_type", "server_code:$srv_key"];
    }

    my $f             = $loop->new_future;
    my $request_start = [Time::HiRes::gettimeofday];

    if ($cmd eq "UserAdd") {
        $param->{pass_main}     = delete $param->{mainPassword};
        $param->{pass_investor} = delete $param->{investPassword};
    } elsif ($cmd eq "UserPasswordChange") {
        $param->{password} = delete $param->{new_password};
    }

    my $in            = encode_json(_prepare_params(%$param));
    my $config        = BOM::Config::mt5_webapi_config();
    my $mt5_proxy_url = $config->{mt5_http_proxy_url};

    my $url = $mt5_proxy_url . '/' . $srv_type . '_' . $srv_key . '/' . $cmd;

    state $http_tiny = HTTP::Tiny->new(timeout => HTTP_TIMEOUT_SECONDS);
    my $response;
    my $success = 0;
    my $out;
    my $result_http;

    try {
        $result_http = $http_tiny->post($url, {content => $in});
        stats_inc('mt5.call.proxy.successful', {tags => $dd_tags});

        $out = $result_http->{content};
        $out =~ s/[\x0D\x0A]//g;
        $out = decode_json($out);

        # Preserve case compatibility. MT5 server returns to MT5 proxy fields in PascalCase,
        # MT5 proxy sometimes convert them to camelCase, but sometimes omits conversion
        # (actual logic on MT5 side is more complex, thus it is not fixed there).
        # Here we ensure that properties up to 2nd level are named using camelCase.
        # TODO: the data model for BOM::MT5::User::Async should be fully defined.
        if (ref $out eq 'HASH') {
            $out = {map { lc $_ => $out->{$_} } keys %$out};
            foreach my $key (keys %$out) {
                if (ref $out->{$key} eq 'HASH') {
                    $out->{$key} = {map { lcfirst($_) => $out->{$key}->{$_} } keys %{$out->{$key}}};
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
            }

            # Append login prefixes for mt5 used id.
            if ($out->{user} && $out->{user}{login}) {
                $out->{user}{login} = $prefix . $out->{user}{login};
            }

            if ($out->{login}) {
                $out->{login} = $prefix . $out->{login};
            }
        }

        $response = $out;
        $success  = 1;
    } catch ($e) {
        my $http_status_code     = (ref $result_http eq 'HASH' && exists $result_http->{status}) ? $result_http->{status} : 'unknown';
        my $http_status_category = categorize_http_status($http_status_code);
        my $error_message        = $http_status_category eq 'success' ? $e                         : $out;
        my $response_code_error  = $http_status_category eq 'success' ? 'SuccessWithErrorResponse' : 'NonSuccessResponse';

        push @$dd_tags, "http_status_category:${http_status_category}";
        stats_inc('mt5.call.proxy.request_error', {tags => $dd_tags});

        $response = {
            code              => $response_code_error,
            error             => $response_code_error,
            message_to_client => $error_message
        };
    }

    stats_timing('mt5.call.proxy.timing', (1000 * Time::HiRes::tv_interval($request_start)), {tags => $dd_tags});

    $success ? return $f->done($response) : return $f->fail($response, mt5 => $cmd);

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

=head2 tick_last

Gets last tick for MT5 symbol

=over 4

=item * C<$login> MT5 manager login id

=item * C<$symbol> MT5 Symbol

=back

returns fields from the TickLast

=cut

sub tick_last {
    my ($login, $symbol) = @_;
    my $param = {
        login  => $login,
        symbol => $symbol
    };

    return _invoke_mt5('TickLast', $param)->then(
        sub {
            my ($response) = @_;

            my $ret = $response->{tick_last}->{details};

            my @final_results;

            for my $tick_detail ($ret->@*) {
                my %new_tick_detail = map { lc $_ => $tick_detail->{$_} } keys $tick_detail->%*;
                push @final_results, \%new_tick_detail;
            }

            return Future->done(\@final_results);
        });

}

=head2 tick_last_group

Gets last tick for MT5 group

=over 4

=item * C<$login> MT5 manager login id

=item * C<$symbol> MT5 Symbol

=item * C<$group> MT5 Group

=back

returns fields from the TickLastGroup

=cut

sub tick_last_group {
    my ($login, $symbol, $group) = @_;
    my $param = {
        login  => $login,
        symbol => $symbol,
        group  => $group
    };

    return _invoke_mt5('TickLastGroup', $param)->then(
        sub {
            my ($response) = @_;

            my $ret = $response->{tick_last_group}->{details};

            my @final_results;

            for my $tick_detail ($ret->@*) {
                my %new_tick_detail = map { lc $_ => $tick_detail->{$_} } keys $tick_detail->%*;
                push @final_results, \%new_tick_detail;
            }

            return Future->done(\@final_results);
        });

}

=head2 get_symbol

Gets MT5 symbols info

=over 4

=item * C<$loginid> MT5 manager login id

=item * C<$symbol> symbol

=back

returns fields from the SymbolGet subroutine

=cut

sub get_symbol {
    my ($login, $symbol) = @_;
    my $param = {
        login  => $login,
        symbol => $symbol
    };

    return _invoke_mt5('SymbolGet', $param)->then(
        sub {
            my ($response) = @_;
            return Future->done($response->{symbol});
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
            my $ret        = $response->{user};
            my @fields     = _get_archive_user_fields();
            my $mt_user;
            $mt_user->{$_} = $ret->{$_} for (@fields);
            return Future->done($mt_user);
        });
}

sub user_archive {
    my $login = shift;
    my $param = {login => $login};

    return _invoke_mt5('UserArchive', $param)->then(
        sub {
            return Future->done({status => 1});
        });
}

=head2 user_restore

Restore MT5 user from archived database to current database.

=over 4

=item * C<$mt5_user> MT5 user data retrieved from user_archive call

=back

returns status;

=cut

sub user_restore {
    my $mt5_user = shift;

    my $user;
    $user->{ucfirst $_} = $mt5_user->{$_} for keys %$mt5_user;
    # y/ is the same as tr/, action of transliterate. It does not support regular expression like s/
    # What it does here is any digit of 0 to 9, matching the complement of that (/c), then replace
    # to make it empty (/d)-delete. Basically remove everything except 0 to 9. Its more efficient than s/ if no regex is needed.
    $user->{$_} && $user->{$_} =~ y/0-9//cd for (qw(Login Agent));
    $user->{LastAccess} = delete $user->{Lastaccess};

    my $param = {
        login => $mt5_user->{login},
        user  => $user
    };

    return _invoke_mt5('UserRestore', $param)->then(
        sub {
            return Future->done({status => 1});
        });
}

sub update_user {
    my $args   = shift;
    my @fields = _get_update_user_fields();

    my $param = {map { $_ => $args->{$_} } grep { defined $args->{$_} } @fields};

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

    BOM::MT5::User::Cached::invalidate_mt5_api_cache($args->{login});
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

    BOM::MT5::User::Cached::invalidate_mt5_api_cache($args->{login});
    return _invoke_mt5('UserDepositChange', $param)->then(
        sub {

            return Future->done({status => 1});
        });
}

sub user_balance_change {
    my $args = shift;

    my $param = {
        login   => $args->{login},
        balance => $args->{user_balance},
        comment => $args->{comment},
        type    => $args->{type}};

    BOM::MT5::User::Cached::invalidate_mt5_api_cache($args->{login});
    return _invoke_mt5('UserBalanceChange', $param)->then(
        sub {

            return Future->done({status => 1});
        });
}

=head2 user_balance_check

This subroutine checks the balance of a specified user account on the MT5 platform. 
It optionally corrects the user's balance and credit funds based on the history of deals.

=over 4

=item * C<$login> (required): The login identifier of the user whose balance is to be checked.

=item * C<$fixflag> (optional): Indicates if client's balance and credit should be corrected post-check. Default is 1 (adjust based on deal history); 0 means no correction.

=back

The subroutine returns a L<Future> object that, on completion, yields a response hashref containing the following keys:

=over 4

=item * C<retcode>: The response code (0 for success, error code otherwise).

=item * C<balance>: The user's balance after correction (user) and before correction (history).

=item * C<credit>: The user's credit funds after correction (user) and before correction (history).

=back

=cut

sub user_balance_check {
    my ($login, $fixflag) = @_;

    my $param = {
        login   => $login,
        fixflag => $fixflag // 1,
    };

    return _invoke_mt5('UserBalanceCheck', $param)->then(
        sub {
            my ($response) = @_;
            return Future->done($response);
        });
}

sub get_open_positions_count {
    my $login = shift;

    return _invoke_mt5('PositionGetTotal', {login => $login})->then(
        sub {
            my ($response) = @_;

            return Future->done({total => $response->{user}{total}});
        });
}

sub get_open_orders_count {
    my $login = shift;

    return _invoke_mt5('OrderGetTotal', {login => $login})->then(
        sub {
            my ($response) = @_;

            return Future->done({total => $response->{order_get_total}{total}});
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

=head2 deal_get_batch

Get deal within a given range

=over 4

=item * C<server> (required) MT5 server, e.g. real_p01_ts01, demo_p01_ts01

=item * C<login> (required) MT5 login, 111231, 123123

=item * C<from> (required) from(epoch), e.g 1649750830, 1649750831

=item * C<to> (required) to(epoch), e.g. 1649756230, 1649756231

=back

=cut

sub deal_get_batch {
    my ($args) = @_;

    # Required params
    my $server = $args->{server};
    my $login  = $args->{login};
    my $from   = $args->{from};
    my $to     = $args->{to};

    return _invoke_mt5(
        'DealGetBatch',
        {
            server => $server,
            login  => $login,
            from   => $from,
            to     => $to
        }
    )->then(
        sub {
            my ($response) = @_;

            return Future->done($response);
        });
}

=head2 categorize_http_status

Categorize an HTTP status code into a specific category.

=over 4

=item * C<status_code> (required) HTTP status code to categorize.

=back

This subroutine categorizes an HTTP status code into one of five categories: 
    Informational (100-199)
    Success (200-299)
    Redirection (300-399)
    Client Error (400-499)
    Server Error (500-599)

If the status code does not fall into these categories, 'unknown' is returned.

Examples:

    categorize_http_status(100); # Returns 'informational'
    categorize_http_status(200); # Returns 'success'
    categorize_http_status(300); # Returns 'redirection'
    categorize_http_status(404); # Returns 'client_error'
    categorize_http_status(500); # Returns 'server_error'
    categorize_http_status(600); # Returns 'unknown'

=cut

sub categorize_http_status {
    my ($status_code) = @_;

    # Use regex to categorize the status code
    return 'informational' if $status_code =~ /^1\d\d$/;
    return 'success'       if $status_code =~ /^2\d\d$/;
    return 'redirection'   if $status_code =~ /^3\d\d$/;
    return 'client_error'  if $status_code =~ /^4\d\d$/;
    return 'server_error'  if $status_code =~ /^5\d\d$/;

    return 'unknown';
}

1;
