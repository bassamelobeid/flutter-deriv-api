package BOM::OAuth::O;

use Mojo::Base 'Mojolicious::Controller';
use Date::Utility;
# login
use Email::Valid;
use Mojo::Util qw(url_escape);
use List::MoreUtils qw(any);

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

    my ($client, $session_token);
    if (    $c->req->method eq 'POST'
        and ($c->csrf_token eq ($c->param('csrftoken') // ''))
        and $c->param('login'))
    {
        ($client, $session_token) = $c->__login($app) or return;
    } elsif ($c->req->method eq 'POST') {
        # we force login no matter user is in or not
        $client = $c->__get_client;
    }

    ## check user is logined
    unless ($client) {
        ## show login form
        return $c->render(
            template => 'login',
            layout   => 'default',

            app       => $app,
            l         => \&localize,
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
            csrftoken => $c->csrf_token,
        );
    }

    if ($session_token) {
        my $session = BOM::Platform::SessionCookie->new({token => $session_token});
        if ($session and $session->have_multiple_sessions) {
            send_email({
                    from    => BOM::Platform::Static::Config::get_customer_support_email(),
                    to      => $session->email,
                    subject => localize('New Sign-In Activity Detected'),
                    message => [
                        localize(
                            'An additional sign-in has just been detected on your account [_1] from the following IP address: [_2]. If this additional sign-in was not performed by you, and / or you have any related concerns, please contact our Customer Support team.',
                            $session->email,
                            $c->stash('request')->client_ip
                        )
                    ],
                    use_email_template => 1,
                });
        }
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

    $c->redirect_to($uri);
}

sub __login {
    my ($c, $app) = @_;

    my ($err, $user, $client) = $c->__validate_login();
    if ($err) {
        $c->render(
            template => 'login',
            layout   => 'default',

            app       => $app,
            error     => $err,
            l         => \&localize,
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
        expires => time + 86400 * 2,
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

    # reset csrf_token
    delete $c->session->{csrf_token};

    return ($client, $session_token);
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

sub __validate_login {
    my ($c) = @_;

    my $email    = $c->param('email');
    my $password = $c->param('password');

    if (not $email or not Email::Valid->address($email)) {
        return localize('Email not given.');
    }

    if (not $password) {
        return localize('Password not given.');
    }

    my $user = BOM::Platform::User->new({email => $email})
        or return localize('Invalid email and password combination.');

    my $result = $user->login(
        password    => $password,
        environment => $c->__login_env(),
    );
    return $result->{error} if $result->{error};

    # clients are ordered by reals-first, then by loginid.  So the first is the 'default'
    my @clients = $user->clients;
    my $client  = $clients[0];
    if ($result = $client->login_error()) {
        return $result;
    }

    return (undef, $user, $client);
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

1;
