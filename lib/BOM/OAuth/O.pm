package BOM::OAuth::O;

use strict;
use warnings;

use Mojo::Base 'Mojolicious::Controller';
use Date::Utility;
use Try::Tiny;
use Digest::MD5 qw(md5_hex);
use Email::Valid;
use Mojo::Util qw(url_escape);
use List::MoreUtils qw(any firstval);
use HTML::Entities;
use Format::Util::Strings qw( defang );
use List::MoreUtils qw(none);

use BOM::User::Client;
use LandingCompany::Registry;
use Brands;

use BOM::Config::Runtime;
use BOM::User;
use BOM::User::TOTP;
use BOM::Platform::Email qw(send_email);
use BOM::Database::Model::OAuth;
use BOM::OAuth::Helper;
use BOM::User::AuditLog;
use BOM::Platform::Context qw(localize);
use DataDog::DogStatsd::Helper qw(stats_inc);
use BOM::OAuth::Static qw(get_message_mapping);

sub authorize {
    my $c = shift;

    # APP_ID verification logic
    my ($app_id, $state) = map { defang($c->param($_)) // undef } qw/ app_id state /;

    return $c->_bad_request('the request was missing app_id') unless $app_id;
    return $c->_bad_request('the request was missing valid app_id') if ($app_id !~ /^\d+$/);

    my $oauth_model = _oauth_model();
    my $app         = $oauth_model->verify_app($app_id);

    return $c->_bad_request('the request was missing valid app_id') unless $app;

    # setup oneall callback url
    my $oneall_callback = $c->req->url->path('/oauth2/oneall/callback')->to_abs;
    $c->stash('oneall_callback' => $oneall_callback);

    my $brand_name = BOM::OAuth::Helper->extract_brand_from_params($c->stash('request')->params) // $c->stash('brand')->name;

    # load available networks for brand
    $c->stash('login_providers' => Brands->new(name => $brand_name)->login_providers);

    my $client;

    # try to retrieve client from session

    if (    $c->req->method eq 'POST'
        and ($c->csrf_token eq (defang($c->param('csrf_token')) // ''))
        and defang($c->param('login')))
    {

        $client = $c->_login($app) or return;
        $c->session('_is_logined', 1);
        $c->session('_loginid',    $client->loginid);

    } elsif ($c->req->method eq 'POST' and $c->session('_is_logined')) {

        # Get loginid from Mojo Session
        $client = $c->_get_client;

    } elsif ($c->session('_oneall_user_id')) {

        # Prevent Japan IP access social login feature.
        if ($c->stash('request')->country_code ne 'jp') {

            # Get client from Oneall Social Login.
            my $oneall_user_id = $c->session('_oneall_user_id');
            $client = $c->_login($app, $oneall_user_id) or return;
            $c->session('_is_logined', 1);
            $c->session('_loginid',    $client->loginid);

        }
    }

    my %template_params = (
        template         => _get_login_template_name($brand_name),
        layout           => $brand_name,
        app              => $app,
        r                => $c->stash('request'),
        csrf_token       => $c->csrf_token,
        use_social_login => $c->_is_social_login_available(),
        login_providers  => $c->stash('login_providers'),
        login_method     => undef,
    );

    # detect and validate social_login param if provided
    if (my $method = $c->param('social_signup')) {
        if (!$c->param('email') and !$c->param('password')) {
            if (_is_social_login_suspended()) {
                stats_inc_error($brand_name, "TEMP_DISABLED");
                $template_params{error} = localize(get_message_mapping()->{TEMP_DISABLED});
                return $c->render(%template_params);
            }
            if (not grep { $method eq $_ } @{$c->stash('login_providers')}) {
                stats_inc_error($brand_name, "INVALID_SOCIAL");
                return $c->_bad_request('the request was missing valid social login method');
            }
            $template_params{login_method} = $method;
            return $c->render(%template_params);
        }
    }

    # show error when no client found in session show login form
    if (!$client) {
        $template_params{error} = delete $c->session->{error} || '';
        return $c->render(%template_params);
    }

    my $user = $client->user or die "no user for email " . $client->email;

    my $is_verified = $c->session('_otp_verified') // 0;
    my $otp_error = '';
    # If the User has provided OTP, verify it
    if (    $c->req->method eq 'POST'
        and ($c->csrf_token eq (defang($c->param('csrf_token')) // ''))
        and defang($c->param('totp_proceed')))
    {
        my $otp = defang($c->param('otp'));
        $is_verified = BOM::User::TOTP->verify_totp($user->{secret_key}, $otp);
        $c->session('_otp_verified', $is_verified);
        $otp_error = localize(get_message_mapping->{TFA_FAILURE});
        stats_inc_error($brand_name, "TFA_FAILURE");
    }

    # Check if user has enabled 2FA authentication and this is not a scope request
    if ($user->{is_totp_enabled} && !$is_verified) {
        return $c->render(
            template   => $brand_name . '/totp',
            layout     => $brand_name,
            app        => $app,
            error      => $otp_error,
            r          => $c->stash('request'),
            csrf_token => $c->csrf_token,
        );
    }

    my $redirect_uri = $app->{redirect_uri};

    # confirm scopes
    my $is_all_approved = 0;
    if (    $c->req->method eq 'POST'
        and ($c->csrf_token eq (defang($c->param('csrf_token')) // ''))
        and (defang($c->param('cancel_scopes')) || defang($c->param('confirm_scopes'))))
    {
        if (defang($c->param('confirm_scopes'))) {
            # approval on all loginids
            foreach my $c1 ($user->clients) {
                $is_all_approved = $oauth_model->confirm_scope($app_id, $c1->loginid);
            }
        } elsif ($c->param('cancel_scopes')) {
            my $uri = Mojo::URL->new($redirect_uri);
            $uri .= '#error=scope_denied';
            $uri .= '&state=' . $state if defined $state;
            # clear session for oneall login when scope is canceled
            delete $c->session->{_oneall_user_id};
            delete $c->session->{_otp_verified};
            return $c->redirect_to($uri);
        }
    }

    my $loginid = $client->loginid;
    $is_all_approved = 1 if $app_id eq '1';
    $is_all_approved ||= $oauth_model->is_scope_confirmed($app_id, $loginid);

    # show scope confirms if not yet approved
    # do not show the scope confirm screen if APP ID is 1

    return $c->render(
        template   => $brand_name . '/scope_confirms',
        layout     => $brand_name,
        app        => $app,
        client     => $client,
        scopes     => \@{$app->{scopes}},
        r          => $c->stash('request'),
        csrf_token => $c->csrf_token,
    ) unless $is_all_approved;

    # setting up client ip

    my $client_ip = $c->client_ip;
    if ($c->tx and $c->tx->req and $c->tx->req->headers->header('REMOTE_ADDR')) {
        $client_ip = $c->tx->req->headers->header('REMOTE_ADDR');
    }

    my $ua_fingerprint = md5_hex($app_id . ($client_ip // '') . ($c->req->headers->header('User-Agent') // ''));

    # create tokens for all loginids
    my $i = 1;
    my @params;
    foreach my $c1 ($user->clients) {
        my ($access_token) = $oauth_model->store_access_token_only($app_id, $c1->loginid, $ua_fingerprint);
        push @params,
            (
            'acct' . $i  => $c1->loginid,
            'token' . $i => $access_token,
            $c1->default_account ? ('cur' . $i => $c1->default_account->currency_code) : (),
            );
        $i++;
    }

    push @params, (state => $state) if defined $state;

    my $uri = Mojo::URL->new($redirect_uri);
    $uri->query(\@params);

    stats_inc('login.authorizer.success', {tags => ["brand:$brand_name", "two_factor_auth:$is_verified"]});

    # clear login session
    delete $c->session->{_is_logined};
    delete $c->session->{_loginid};
    delete $c->session->{_oneall_user_id};
    delete $c->session->{_otp_verified};
    $c->session(expires => 1);

    $c->redirect_to($uri);
}

sub _login {
    my ($c, $app, $oneall_user_id) = @_;

    my ($user, $last_login, $err, $client);

    my $email      = lc defang($c->param('email'));
    my $password   = $c->param('password');
    my $brand      = $c->stash('brand');
    my $brand_name = BOM::OAuth::Helper->extract_brand_from_params($c->stash('request')->params) // $brand->name;

    # TODO get rid of LOGIN label
    LOGIN:
    {
        if ($oneall_user_id) {
            $password = '**SOCIAL-LOGIN-ONEALL**';

            $user = BOM::User->new(id => $oneall_user_id);
            unless ($user) {
                $err = "INVALID_USER";
                last;
            }

        } else {
            if (not $email or not Email::Valid->address($email)) {
                $err = "INVALID_EMAIL";
                last;
            }

            if (not $password) {
                $err = "INVALID_PASSWORD";
                last;
            }

            $user = BOM::User->new(email => $email);

            unless ($user) {
                $err = "USER_NOT_FOUND";
                last;
            }

            # Prevent login if social signup flag is found.
            # As the main purpose of this controller is to serve
            # clients with email/password only.

            if ($user->{has_social_signup}) {
                $err = "NO_SOCIAL_SIGNUP";
                last;
            }

        }

        if (BOM::Config::Runtime->instance->app_config->system->suspend->all_logins) {

            $err = "TEMP_DISABLED";
            BOM::User::AuditLog::log('system suspend all login', $user->{email});
            last;
        }

        # get last login before current login to get last record
        $last_login = $user->get_last_successful_login_history();

        my $result = $user->login(
            password        => $password,
            environment     => $c->_login_env(),
            is_social_login => $oneall_user_id ? 1 : 0,
        );

        last if ($err = $result->{error});

        my @clients = $user->clients;
        $client = $clients[0];

        if (grep { $client->loginid =~ /^$_/ } @{BOM::Config::Runtime->instance->app_config->system->suspend->logins}) {
            $err = "TEMP_DISABLED";
        } elsif ($client->status->get('disabled')) {
            $err = "DISABLED";
        }
    }

    if ($err) {

        stats_inc_error($brand_name, $err);

        $c->render(
            template         => _get_login_template_name($brand_name),
            layout           => $brand_name,
            app              => $app,
            error            => localize(get_message_mapping()->{$err} // $err),
            r                => $c->stash('request'),
            csrf_token       => $c->csrf_token,
            use_social_login => $c->_is_social_login_available(),
            login_providers  => $c->stash('login_providers'),
            login_method     => undef,
        );

        return;

    }

    my $r       = $c->stash('request');
    my $options = {
        domain  => $r->cookie_domain,
        secure  => ($r->cookie_domain eq '127.0.0.1') ? 0 : 1,
        path    => '/',
        expires => time + 86400 * 60,
    };

    $c->cookie(
        email => url_escape($user->{email}),
        $options
    );
    $c->cookie(
        loginid_list => url_escape($user->loginid_list_cookie_val),
        $options
    );
    $c->_set_reality_check_cookie($user, $options);

    $c->cookie(
        loginid => $client->loginid,
        $options
    );
    $c->cookie(
        residence => $client->residence,
        $options
    );

    # send when client already has login session(s) and its not backoffice (app_id = 4, as we impersonate from backoffice using read only tokens)
    if ($app->{id} ne '4' and _oauth_model()->has_other_login_sessions($client->loginid)) {
        try {
            if ($last_login and exists $last_login->{environment}) {
                my ($old_env, $user_agent, $r) =
                    (_get_details_from_environment($last_login->{environment}), $c->req->headers->header('User-Agent') // '', $c->stash('request'));

                # need to compare first two octet only
                my ($old_ip, $new_ip, $country_code) = ($old_env->{ip}, $r->client_ip // '', uc($r->country_code // ''));
                ($old_ip) = $old_ip =~ /(^(\d{1,3}\.){2})/;
                ($new_ip) = $new_ip =~ /(^(\d{1,3}\.){2})/;

                if (($old_ip ne $new_ip or $old_env->{country} ne $country_code)
                    and $old_env->{user_agent} ne $user_agent)
                {
                    my $message;
                    if ($app->{id} eq '1') {
                        $message = localize(
                            get_message_mapping()->{ADDITIONAL_SIGNIN},
                            $client->email, $r->client_ip,
                            $brand->countries_instance->countries->country_from_code($country_code) // $country_code,
                            encode_entities($user_agent));
                    } else {
                        $message = localize(
                            get_message_mapping()->{ADDITIONAL_SIGNIN_THIRD_PARTY},
                            $client->email, $r->client_ip, $country_code, encode_entities($user_agent),
                            $app->{name});
                    }

                    send_email({
                        from                  => $brand->emails('support'),
                        to                    => $client->email,
                        subject               => localize(get_message_mapping()->{NEW_SIGNIN_ACTIVITY}),
                        message               => [$message],
                        use_email_template    => 1,
                        email_content_is_html => 1,
                        template_loginid      => $client->loginid,
                    });
                }
            }
        };
    }

    # reset csrf_token
    delete $c->session->{csrf_token};
    return $client;
}

# fetch social login feature status from settings
sub _is_social_login_suspended {
    return BOM::Config::Runtime->instance->app_config->system->suspend->social_logins;
}

# determine availability status of social login feature
# disable feature for Japanese language and for Japan IP
sub _is_social_login_available {
    my $c = shift;

    return (
        not _is_social_login_suspended() and scalar @{$c->stash('login_providers')} > 0 and ($c->stash('request')->country_code ne 'jp'
            and $c->stash('request')->language ne 'JA'));
}

sub _oauth_model {
    return BOM::Database::Model::OAuth->new;
}

sub _set_reality_check_cookie {
    my ($c, $user, $options) = @_;

    my $r = $c->stash('request');

    # set this cookie only once
    return if $r->cookie('reality_check');

    return unless any { LandingCompany::Registry->get_by_broker($_->broker_code)->has_reality_check } $user->clients;

    my $default_reality_check_interval_in_minutes = 60;
    $c->cookie(
        'reality_check' => url_escape($default_reality_check_interval_in_minutes . ',' . time),
        $options
    );

    return;
}

sub _login_env {
    my $c = shift;
    my $r = $c->stash('request');

    my $now                = Date::Utility->new->datetime_ddmmmyy_hhmmss_TZ;
    my $ip_address         = $r->client_ip || '';
    my $ip_address_country = uc $r->country_code || '';
    my $ua                 = $c->req->headers->header('User-Agent') || '';
    my $lang               = uc $r->language || '';
    my $environment        = "$now IP=$ip_address IP_COUNTRY=$ip_address_country User_AGENT=$ua LANG=$lang";
    return $environment;
}

sub _get_client {
    my $c = shift;

    my $client = BOM::User::Client->new({
        loginid      => $c->session('_loginid'),
        db_operation => 'replica'
    });
    return undef if $client->status->get('disabled');

    return $client;
}

sub _bad_request {
    my ($c, $error) = @_;

    return $c->throw_error('invalid_request', $error);
}

sub _get_details_from_environment {
    my $env = shift;

    return unless $env;

    my ($ip) = $env =~ /(IP=(\d{1,3}\.){3}\d{1,3})/i;
    $ip =~ s/IP=//i;
    my ($country) = $env =~ /(IP_COUNTRY=\w{1,2})/i;
    $country =~ s/IP_COUNTRY=//i if $country;
    my ($user_agent) = $env =~ /(User_AGENT.+(?=\sLANG))/i;
    $user_agent =~ s/User_AGENT=//i;

    return {
        ip         => $ip,
        country    => uc($country // 'unknown'),
        user_agent => $user_agent
    };
}

sub _get_login_template_name {
    my $brand_name = shift;

    return $brand_name . '/login';
}

sub stats_inc_error {
    my ($brand_name, $failure_message) = @_;
    stats_inc('login.authorizer.validation_failure', {tags => ["brand:$brand_name", "error:$failure_message"]});
}

1;
