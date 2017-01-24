package BOM::OAuth::O;

use Mojo::Base 'Mojolicious::Controller';
use Date::Utility;
use Try::Tiny;
use Digest::MD5 qw(md5_hex);
use Email::Valid;
use Mojo::Util qw(url_escape);
use List::MoreUtils qw(any firstval);
use HTML::Entities;

use Client::Account;
use LandingCompany::Registry;

use BOM::Platform::Runtime;
use BOM::Platform::Context qw(localize);
use BOM::Platform::User;
use BOM::Platform::Email qw(send_email);
use BOM::Database::Model::OAuth;

sub _oauth_model {
    return BOM::Database::Model::OAuth->new;
}

sub authorize {
    my $c = shift;

    my ($app_id, $state, $response_type) = map { $c->param($_) // undef } qw/ app_id state response_type /;

    # $response_type ||= 'code';    # default to Authorization Code
    $response_type = 'token';    # only support token

    $app_id or return $c->_bad_request('the request was missing app_id');

    return $c->_bad_request('the request was missing valid app_id') if ($app_id !~ /^\d+$/);

    my $oauth_model = _oauth_model();
    my $app         = $oauth_model->verify_app($app_id);
    unless ($app) {
        return $c->_bad_request('the request was missing valid app_id');
    }

    my @scopes          = @{$app->{scopes}};
    my $redirect_uri    = $app->{redirect_uri};
    my $redirect_handle = sub {
        my ($response_type, $error, $state) = @_;

        my $uri = Mojo::URL->new($redirect_uri);
        $uri .= '#error=' . $error;
        $uri .= '&state=' . $state if defined $state;
        return $uri;
    };

    ## setup oneall callback url
    my $oneall_callback = $c->req->url->path('/oauth2/oneall/callback')->to_abs;
    $c->stash('oneall_callback' => $oneall_callback);

    my $client;
    if (    $c->req->method eq 'POST'
        and ($c->csrf_token eq ($c->param('csrftoken') // ''))
        and $c->param('login'))
    {
        $client = $c->_login($app) or return;
        $c->session('_is_logined', 1);
        $c->session('_loginid',    $client->loginid);
    } elsif ($c->req->method eq 'POST' and $c->session('_is_logined')) {
        # get loginid from Mojo Session
        $client = $c->_get_client;
    } elsif ($c->session('_oneall_user_id')) {
        ## from Oneall Social Login
        my $oneall_user_id = $c->session('_oneall_user_id');
        $client = $c->_login($app, $oneall_user_id) or return;
        $c->session('_is_logined', 1);
        $c->session('_loginid',    $client->loginid);
    }

    # set session on first page visit (GET)
    # for binary.com, app id = 1
    if ($app_id eq '1' and $c->req->method eq 'GET') {
        my $r           = $c->stash('request');
        my $referer     = $c->req->headers->header('Referer') // '';
        my $domain_name = $r->domain_name;
        $domain_name =~ s/^oauth//;
        if (index($referer, $domain_name) > -1) {
            $c->session('_is_app_approved' => 1);
        } else {
            $c->session('_is_app_approved' => 0);
        }
    }

    my $brand_name = $c->stash('brand')->name;
    ## check user is logined
    unless ($client) {
        ## taken error from oneall
        my $error = '';
        if ($error = $c->session('_oneall_error')) {
            delete $c->session->{_oneall_error};
        }

        ## show login form
        return $c->render(
            template  => _get_login_template_name($app_id, $brand_name),
            layout    => $brand_name,
            app       => $app,
            error     => $error,
            r         => $c->stash('request'),
            csrftoken => $c->csrf_token,
        );
    }

    my $loginid = $client->loginid;
    my $user = BOM::Platform::User->new({email => $client->email}) or die "no user for email " . $client->email;

    ## confirm scopes
    my $is_all_approved = 0;
    if (    $c->req->method eq 'POST'
        and ($c->csrf_token eq ($c->param('csrftoken') // ''))
        and ($c->param('cancel_scopes') || $c->param('confirm_scopes')))
    {
        if ($c->param('confirm_scopes')) {
            ## approval on all loginids
            foreach my $c1 ($user->clients) {
                $is_all_approved = $oauth_model->confirm_scope($app_id, $c1->loginid);
            }
        } else {
            my $uri = $redirect_handle->($response_type, 'scope_denied', $state);
            return $c->redirect_to($uri);
        }
    }

    ## if app_id=1 and referer is binary.com, we do not show the scope confirm screen
    if ($app_id eq '1' and $c->session('_is_app_approved')) {
        $is_all_approved = 1;
    }

    ## check if it's confirmed
    $is_all_approved ||= $oauth_model->is_scope_confirmed($app_id, $loginid);
    unless ($is_all_approved) {
        ## show scope confirms
        return $c->render(
            template  => $brand_name . '/scope_confirms',
            layout    => $brand_name,
            app       => $app,
            client    => $client,
            scopes    => \@scopes,
            r         => $c->stash('request'),
            csrftoken => $c->csrf_token,
        );
    }

    my $client_ip = $c->client_ip;
    if ($c->tx and $c->tx->req and $c->tx->req->headers->header('REMOTE_ADDR')) {
        $client_ip = $c->tx->req->headers->header('REMOTE_ADDR');
    }

    my $ua_fingerprint = md5_hex($app_id . ($client_ip // '') . ($c->req->headers->header('User-Agent') // ''));

    ## create tokens for all loginids
    my $i = 1;
    my @params;
    foreach my $c1 ($user->clients) {
        my ($access_token, $expires_in) = $oauth_model->store_access_token_only($app_id, $c1->loginid, $ua_fingerprint);

        # loginid
        my $key = 'acct' . $i;
        push @params, ($key => $c1->loginid);

        # token
        $key = 'token' . $i++;
        push @params, ($key => $access_token);
    }

    push @params, (state => $state) if defined $state;

    my $uri = Mojo::URL->new($redirect_uri);
    $uri->query(\@params);

    ## clear session
    delete $c->session->{_is_logined};
    delete $c->session->{_loginid};
    delete $c->session->{_is_app_approved};
    delete $c->session->{_oneall_user_id};

    $c->redirect_to($uri);
}

sub _login {
    my ($c, $app, $oneall_user_id) = @_;

    my ($user, $client, $last_login, $err);

    my ($email, $password) = ($c->param('email'), $c->param('password'));
    LOGIN:
    {
        if ($oneall_user_id) {
            $password = '**SOCIAL-LOGIN-ONEALL**';

            $user = BOM::Platform::User->new({id => $oneall_user_id});
            unless ($user) {
                $err = localize('Invalid user.');
                last;
            }
        } else {
            if (not $email or not Email::Valid->address($email)) {
                $err = localize('Email not given.');
                last;
            }

            if (not $password) {
                $err = localize('Password not given.');
                last;
            }

            $user = BOM::Platform::User->new({email => $email});
            unless ($user) {
                $err = localize('Incorrect email or password.');
                last;
            }
        }

        # get last login before current login to get last record
        $last_login = $user->get_last_successful_login_history();
        my $result = $user->login(
            password        => $password,
            environment     => $c->_login_env(),
            is_social_login => $oneall_user_id ? 1 : 0,
        );

        last if ($err = $result->{error});

        # clients are ordered by reals-first, then by loginid.  So the first is the 'default'
        my @clients = $user->clients;
        $client = $clients[0];

        # get 1st loginid, which is not currently self-excluded until
        if (exists $result->{self_excluded}) {
            $client = firstval { !exists $result->{self_excluded}->{$_->loginid} } (@clients);
        }

        if (grep { $client->loginid =~ /^$_/ } @{BOM::Platform::Runtime->instance->app_config->system->suspend->logins}) {
            $err = localize('Login to this account has been temporarily disabled due to system maintenance. Please try again in 30 minutes.');
        } elsif ($client->get_status('disabled')) {
            $err = localize('This account is unavailable. For any questions please contact Customer Support.');
        } elsif (my $self_exclusion_dt = $client->get_self_exclusion_until_dt) {
            $err = localize('Sorry, you have excluded yourself until [_1].', $self_exclusion_dt);
        }
    }

    my $brand = $c->stash('brand');
    if ($err) {
        $c->render(
            template  => _get_login_template_name($app->{id}, $brand->name),
            layout    => $brand->name,
            app       => $app,
            error     => $err,
            r         => $c->stash('request'),
            csrftoken => $c->csrf_token,
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
        email => url_escape($user->email),
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
                            'An additional sign-in has just been detected on your account [_1] from the following IP address: [_2], country: [_3] and browser: [_4]. If this additional sign-in was not performed by you, and / or you have any related concerns, please contact our Customer Support team.',
                            $client->email,
                            $r->client_ip,
                            $brand->countries_instance->countries->country_from_code($country_code) // $country_code,
                            encode_entities($user_agent));
                    } else {
                        $message = localize(
                            'An additional sign-in has just been detected on your account [_1] from the following IP address: [_2], country: [_3], browser: [_4] and app: [_5]. If this additional sign-in was not performed by you, and / or you have any related concerns, please contact our Customer Support team.',
                            $client->email, $r->client_ip, $country_code, encode_entities($user_agent), $app->{name});
                    }

                    send_email({
                        from                  => $brand->emails('support'),
                        to                    => $client->email,
                        subject               => localize('New Sign-In Activity Detected'),
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

sub _set_reality_check_cookie {
    my ($c, $user, $options) = @_;

    my $r = $c->stash('request');

    # set this cookie only once
    return if $r->cookie('reality_check');

    return unless any { LandingCompany::Registry::get_by_broker($_->broker_code)->has_reality_check } $user->clients;

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

    my $client = Client::Account->new({loginid => $c->session('_loginid')});
    return if $client->get_status('disabled');
    return if $client->get_self_exclusion_until_dt;    # Excluded

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
    my ($app_id, $brand_name) = @_;

    # we have different login template for binary.com
    # and for other apps
    if ($app_id eq '1' and $brand_name =~ /^binary$/) {
        return 'binary/loginbinary';
    }

    return $brand_name . '/login';
}

1;
