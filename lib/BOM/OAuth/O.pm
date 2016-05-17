package BOM::OAuth::O;

use Mojo::Base 'Mojolicious::Controller';
use Date::Utility;
use Try::Tiny;
# login
use Email::Valid;
use Mojo::Util qw(url_escape);
use List::MoreUtils qw(any firstval);

use BOM::Platform::Runtime;
use BOM::Platform::Context qw(localize);
use BOM::Platform::Client;
use BOM::Platform::User;
use BOM::Platform::Static::Config;
use BOM::Platform::Email qw(send_email);
use BOM::Database::Model::OAuth;

sub __oauth_model {
    state $oauth_model = BOM::Database::Model::OAuth->new;
    return $oauth_model;
}

sub authorize {
    my $c = shift;

    my ($app_id, $state, $response_type) = map { $c->param($_) // undef } qw/ app_id state response_type /;

    # $response_type ||= 'code';    # default to Authorization Code
    $response_type = 'token';    # only support token

    $app_id or return $c->__bad_request('the request was missing app_id');

    my $oauth_model = __oauth_model();
    my $app         = $oauth_model->verify_app($app_id);
    unless ($app) {
        return $c->__bad_request('the request was missing valid app_id');
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

    my $client;
    if (    $c->req->method eq 'POST'
        and ($c->csrf_token eq ($c->param('csrftoken') // ''))
        and $c->param('login'))
    {
        $client = $c->__login($app) or return;
        $c->session('__is_logined', 1);
    } elsif ($c->req->method eq 'POST' and $c->session('__is_logined')) {
        # we force login no matter user is in or not
        $client = $c->__get_client;
    }

    # set session on first page visit (GET)
    # for binary.com, app id = 1
    if ($app_id eq '1' and $c->req->method eq 'GET') {
        my $r           = $c->stash('request');
        my $referer     = $c->req->headers->header('Referer') // '';
        my $domain_name = $r->domain_name;
        if (index($referer, $domain_name) > -1) {
            $c->session('__is_app_approved' => 1);
        } else {
            $c->session('__is_app_approved' => 0);
        }
    }

    ## check user is logined
    unless ($client) {
        ## show login form
        return $c->render(
            template => $app_id eq '1' ? 'loginbinary' : 'login',
            layout => 'default',

            app       => $app,
            l         => \&localize,
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
    if ($app_id eq '1' and $c->session('__is_app_approved')) {
        $is_all_approved = 1;
    }

    ## check if it's confirmed
    $is_all_approved ||= $oauth_model->is_scope_confirmed($app_id, $loginid);
    unless ($is_all_approved) {
        ## show scope confirms
        return $c->render(
            template => 'scope_confirms',
            layout   => 'default',

            app       => $app,
            client    => $client,
            scopes    => \@scopes,
            l         => \&localize,
            r         => $c->stash('request'),
            csrftoken => $c->csrf_token,
        );
    }

    my $uri = Mojo::URL->new($redirect_uri);

    ## create tokens for all loginids
    my $i = 1;
    my @accts;
    foreach my $c1 ($user->clients) {
        my ($access_token, $expires_in) = $oauth_model->store_access_token_only($app_id, $c1->loginid, @scopes);
        push @accts, 'acct' . $i . '=' . $c1->loginid . '&token' . $i . '=' . $access_token;
        $i++;
    }

    $uri .= '#' . join('&', @accts);
    $uri .= '&state=' . $state if defined $state;

    ## clear session
    delete $c->session->{__is_logined};
    delete $c->session->{__is_app_approved};

    $c->redirect_to($uri);
}

sub __login {
    my ($c, $app) = @_;

    my ($email, $password) = ($c->param('email'), $c->param('password'));
    my ($user, $client, $last_login, $err);

    LOGIN:
    {
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
            $err = localize('Invalid email and password combination.');
            last;
        }

        # get last login before current login to get last record
        $last_login = $user->get_last_successful_login_history();
        my $result = $user->login(
            password    => $password,
            environment => $c->__login_env(),
        );

        last if ($err = $result->{error});

        # clients are ordered by reals-first, then by loginid.  So the first is the 'default'
        my @clients = $user->clients;
        $client = $clients[0];

        # get 1st loginid, which is not currently self-excluded until
        if (exists $result->{self_excluded}) {
            $client = firstval { !exists $result->{self_excluded}->{$_->loginid} } (@clients);
        }

        if ($result = $client->login_error()) {
            $err = $result;
        }
    }

    if ($err) {
        $c->render(
            template => $app->{id} eq '1' ? 'loginbinary' : 'login',
            layout => 'default',

            app       => $app,
            error     => $err,
            l         => \&localize,
            r         => $c->stash('request'),
            csrftoken => $c->csrf_token,
        );
        return;
    }

    ## set session cookie?
    state $app_config = BOM::Platform::Runtime->instance->app_config;
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
    $c->__set_reality_check_cookie($user, $options);

    my $session = BOM::Platform::SessionCookie->new({
            loginid => $client->loginid,
            email   => $client->email,
            loginat => $r->session_cookie && $r->session_cookie->loginat,
            scopes  => [qw(price chart trade password cashier)]});
    my $session_token = $session->token;
    $c->cookie(
        $app_config->cgi->cookie_name->login => url_escape($session_token),
        $options
    );
    $c->cookie(
        loginid => $client->loginid,
        $options
    );
    $c->cookie(
        residence => $client->residence,
        $options
    );

    if ($session->have_multiple_sessions) {
        try {
            if ($last_login and exists $last_login->{environment}) {
                my ($old_env, $user_agent, $r) =
                    (__get_details_from_environment($last_login->{environment}), $c->req->headers->header('User-Agent') // '', $c->stash('request'));

                # need to compare first two octet only
                my ($old_ip, $new_ip, $country_code) = ($old_env->{ip}, $r->client_ip // '', uc($r->country_code // ''));
                ($old_ip) = $old_ip =~ /(^(\d{1,3}\.){2})/;
                ($new_ip) = $new_ip =~ /(^(\d{1,3}\.){2})/;

                if (($old_ip ne $new_ip or $old_env->{country} ne $country_code)
                    and $old_env->{user_agent} ne $user_agent)
                {
                    send_email({
                            from    => BOM::Platform::Static::Config::get_customer_support_email(),
                            to      => $session->email,
                            subject => localize('New Sign-In Activity Detected'),
                            message => [
                                localize(
                                    'An additional sign-in has just been detected on your account [_1] from the following IP address: [_2], country: [_3] and browser: [_4]. If this additional sign-in was not performed by you, and / or you have any related concerns, please contact our Customer Support team.',
                                    $session->email, $r->client_ip, $country_code, $user_agent
                                )
                            ],
                            use_email_template => 1,
                        });
                }
            }
        };
    }

    # reset csrf_token
    delete $c->session->{csrf_token};

    return $client;
}

sub __set_reality_check_cookie {
    my ($c, $user, $options) = @_;

    my $r = $c->stash('request');

    # set this cookie only once
    return if $r->cookie('reality_check');

    my %rck_brokers = map { $_->code => 1 } @{$r->website->reality_check_broker_codes};
    return unless any { $rck_brokers{$_->broker_code} } $user->clients;

    my $rck_interval = $r->website->reality_check_interval;
    $c->cookie(
        'reality_check' => url_escape($rck_interval . ',' . time),
        $options
    );

    return;
}

sub __login_env {
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

sub __get_client {
    my $c = shift;

    my $request        = $c->stash('request');       # from before_dispatch
    my $session_cookie = $request->session_cookie;
    return unless $session_cookie and $session_cookie->token;

    my $client = BOM::Platform::Client->new({loginid => $session_cookie->loginid});
    return if $client->get_status('disabled');

    if ($client->get_self_exclusion and $client->get_self_exclusion->exclude_until) {
        my $limit_excludeuntil = $client->get_self_exclusion->exclude_until;
        if (Date::Utility->new->is_before(Date::Utility->new($limit_excludeuntil))) {
            return;
        }
    }

    return $client;
}

sub __bad_request {
    my ($c, $error) = @_;

    return $c->throw_error('invalid_request', $error);
}

sub __get_details_from_environment {
    my $env = shift;

    return unless $env;

    my ($ip) = $env =~ /(IP=(\d{1,3}\.){3}\d{1,3})/i;
    $ip =~ s/IP=//i;
    my ($country) = $env =~ /(IP_COUNTRY=\w{1,2})/i;
    $country =~ s/IP_COUNTRY=//i;
    my ($user_agent) = $env =~ /(User_AGENT.+(?=\sLANG))/i;
    $user_agent =~ s/User_AGENT=//i;

    return {
        ip         => $ip,
        country    => uc $country,
        user_agent => $user_agent
    };
}

1;
