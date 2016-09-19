package BOM::OAuth::O;

use Mojo::Base 'Mojolicious::Controller';
use Date::Utility;
use Try::Tiny;
use Digest::MD5 qw(md5_hex);
# login
use Email::Valid;
use Mojo::Util qw(url_escape);
use List::MoreUtils qw(any firstval);

use BOM::Platform::Context qw(localize);
use BOM::Platform::Client;
use BOM::Platform::User;
use BOM::Platform::Email qw(send_email);
use BOM::Database::Model::OAuth;
use BOM::Platform::LandingCompany::Registry;
use BOM::Platform::Countries;
use BOM::System::Config;

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

    my $id_map = {
        'binarycom'                        => 1,
        'binary-expiryd'                   => 2,
        'binary-riskd'                     => 3,
        'id-ct9oK1jjUNyxvPKYNdqJxuGX7bHvJ' => 10,
        'id-evoGhPBCXfJTRnPcTmJ1yaGGOyD0B' => 11,
        'id-5vndA78d0CUwdZIY8QjmS3fafV8G6' => 12,
        'id-OWBASFFrGSqAAJwXohVbQbK2k2ZIf' => 13,
        'id-vVa9bwUYEFCiMkErZrKvMGtzVMWvZ' => 14,
        'id-avVHmHHAwfUfAFI7wojJE6ZtTc7S2' => 15,
        'id-uWvVBcUiVeClE42Z6yupP6enXU283' => 16,
        'id-h0WqKf4FUjukc4R9KKNTjPHBJ2hbW' => 17,
        'id-OKJY118FaKoGMouqLVSpR0aTcEIgc' => 18,
        'id-U9w4wlBvwakOOo6qlurAdzlhMM9ec' => 19,
        'id-dCQvoX4iE6mnCrmVzNTpohV4w6UfJ' => 20,
        'id-vN7ig1HDXJGLS6ymSvnStPioHyytG' => 21,
        'id-Vb4N24n2Kbki6M6QqLUAbY7YzhtgE' => 22,
        'id-Fyc42BtrzzFm2zNsdqYupfRHw2Uai' => 23,
        'id-feDSSnPS7FurZ6vVaSdapN8TMApmI' => 24,
        'id-vK8W8BBkjqYOeBqFNPoGp0GtBfeCr' => 25,
        'id-sbFB3ptvRVHaPUQX6WBrpAMYnUx0X' => 26,
        'id-MztUdUzmvv6D82jX3kTIV6YQZKNoH' => 27,
        'id-im6XumYsBXJwsgBE7GdPVJOxzokLM' => 28,
        'id-M7WpSJwvGlUbPHGzVeXGUiqLsldd4' => 29,
        'id-8jsvu4KlqAIWe7QfMdooxI1MysKN5' => 30,
        'id-qTwlgHJRdPhSoVlLr0xZSukpBzGZX' => 31,
        'id-Gi4cqASC9Lj5BriayCJ1IMiZIr6M1' => 32,
        'id-UuhLUU58MBvWoVvuueGOFpvuZxy9w' => 33,
        'id-UzqwL5EoykkQfT2oe8W58XiqSkMVj' => 34,
        'id-0NfVVJOTjP7MwibaLUp2mxT1NOBd6' => 35,
        'id-9TOwkNEqEsJNL59sorlquaLcAP5zS' => 36,
        'id-Cqt0tCagVnEqY4bBm27S1MUKXsKpu' => 37,
        'id-8S86TbDrMuYAiKVztuHc4T22uPsXw' => 38,
        'id-4Dif6suvu6raAPQM1J61g8RMfIaGw' => 39,
        'id-ks8ZtIN7CHzdh9DRdCxWYROqfbsUp' => 40,
        'id-2oiodQsKqKmVekhsCdF60FKwKIYt4' => 41,
        'id-FwnhrVstk9kPBnDfocVpk8ZDtNs1V' => 42,
        'id-lzNzcmvdgbB99jBFl3IGO3yLgmUSK' => 43,
        'id-EmcupPkdLUKfScM8vsM6Hc4httJrL' => 44,
        'id-yfBPXh3678sX8W1q6xDvr71pk1VJK' => 45,
    };

    if ($app_id !~ /^\d+$/ and exists $id_map->{$app_id}) {
        $app_id = $id_map->{$app_id};
    }
    return $c->__bad_request('the request was missing valid app_id') if ($app_id !~ /^\d+$/);

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

    ## setup oneall callback url
    my $oneall_callback = $c->req->url->path('/oauth2/oneall/callback')->to_abs;
    $c->stash('oneall_callback' => $oneall_callback);

    my $client;
    if (    $c->req->method eq 'POST'
        and ($c->csrf_token eq ($c->param('csrftoken') // ''))
        and $c->param('login'))
    {
        $client = $c->__login($app) or return;
        $c->session('__is_logined', 1);
        $c->session('__loginid',    $client->loginid);
    } elsif ($c->req->method eq 'POST' and $c->session('__is_logined')) {
        # get loginid from Mojo Session
        $client = $c->__get_client;
    } elsif ($c->session('__oneall_user_id')) {
        ## from Oneall Social Login
        my $oneall_user_id = $c->session('__oneall_user_id');
        $client = $c->__login($app, $oneall_user_id) or return;
        $c->session('__is_logined', 1);
        $c->session('__loginid',    $client->loginid);
    }

    # set session on first page visit (GET)
    # for binary.com, app id = 1
    if ($app_id eq '1' and $c->req->method eq 'GET') {
        my $r           = $c->stash('request');
        my $referer     = $c->req->headers->header('Referer') // '';
        my $domain_name = $r->domain_name;
        $domain_name =~ s/^oauth//;
        if (index($referer, $domain_name) > -1) {
            $c->session('__is_app_approved' => 1);
        } else {
            $c->session('__is_app_approved' => 0);
        }
    }

    ## check user is logined
    unless ($client) {
        ## taken error from oneall
        my $error = '';
        if ($error = $c->session('__oneall_error')) {
            delete $c->session->{__oneall_error};
        }

        ## show login form
        return $c->render(
            template => $app_id eq '1' ? 'loginbinary' : 'login',
            layout => 'default',

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
    delete $c->session->{__is_logined};
    delete $c->session->{__loginid};
    delete $c->session->{__is_app_approved};
    delete $c->session->{__oneall_user_id};

    $c->redirect_to($uri);
}

sub __login {
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
                $err = localize('Invalid email and password combination.');
                last;
            }
        }

        # get last login before current login to get last record
        $last_login = $user->get_last_successful_login_history();
        my $result = $user->login(
            password        => $password,
            environment     => $c->__login_env(),
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
    $c->__set_reality_check_cookie($user, $options);

    $c->cookie(
        loginid => $client->loginid,
        $options
    );
    $c->cookie(
        residence => $client->residence,
        $options
    );

    # send when client already has login session(s) and its not backoffice (app_id = 4, as we impersonate from backoffice using read only tokens)
    if ($app->{id} ne '4' and __oauth_model()->has_other_login_sessions($client->loginid)) {
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
                    my $message;
                    if ($app->{id} eq '1') {
                        $message = localize(
                            'An additional sign-in has just been detected on your account [_1] from the following IP address: [_2], country: [_3] and browser: [_4]. If this additional sign-in was not performed by you, and / or you have any related concerns, please contact our Customer Support team.',
                            $client->email, $r->client_ip,
                            BOM::Platform::Countries->instance->countries->country_from_code($country_code) // $country_code, $user_agent);
                    } else {
                        $message = localize(
                            'An additional sign-in has just been detected on your account [_1] from the following IP address: [_2], country: [_3], browser: [_4] and app: [_5]. If this additional sign-in was not performed by you, and / or you have any related concerns, please contact our Customer Support team.',
                            $client->email, $r->client_ip, $country_code, $user_agent, $app->{name});
                    }

                    send_email({
                        from               => BOM::System::Config::email_address('support'),
                        to                 => $client->email,
                        subject            => localize('New Sign-In Activity Detected'),
                        message            => [$message],
                        use_email_template => 1,
                        template_loginid   => $client->loginid,
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

    return unless any { BOM::Platform::LandingCompany::Registry::get_by_broker($_->broker_code)->has_reality_check } $user->clients;

    my $default_reality_check_interval_in_minutes = 60;
    $c->cookie(
        'reality_check' => url_escape($default_reality_check_interval_in_minutes . ',' . time),
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

    my $client = BOM::Platform::Client->new({loginid => $c->session('__loginid')});
    return if $client->get_status('disabled');
    return if $client->get_self_exclusion_until_dt;    # Excluded

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
    $country =~ s/IP_COUNTRY=//i if $country;
    my ($user_agent) = $env =~ /(User_AGENT.+(?=\sLANG))/i;
    $user_agent =~ s/User_AGENT=//i;

    return {
        ip         => $ip,
        country    => uc($country // 'unknown'),
        user_agent => $user_agent
    };
}

1;
