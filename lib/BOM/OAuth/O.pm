package BOM::OAuth::O;

use strict;
use warnings;

no indirect;

use Mojo::Base 'Mojolicious::Controller';
use Date::Utility;
use Try::Tiny;
use Digest::MD5 qw(md5_hex);
use Email::Valid;
use List::Util qw(any first);
use HTML::Entities;
use Format::Util::Strings qw( defang );
use DataDog::DogStatsd::Helper qw(stats_inc);
use HTTP::BrowserDetect;

use Brands;

use BOM::Config::Runtime;
use BOM::User;
use BOM::User::Client;
use BOM::User::TOTP;
use BOM::Platform::Email qw(send_email);
use BOM::Database::Model::OAuth;
use BOM::OAuth::Helper;
use BOM::User::AuditLog;
use BOM::Platform::Context qw(localize);
use BOM::OAuth::Static qw(get_message_mapping);

use constant APPS_ALLOWED_TO_RESET_PASSWORD      => qw(1 14473 15284);
use constant APPS_ACCESS_PERMISSION_NOT_REQUIRED => qw(1 16929);         # binary.com, deriv.app
use constant APPS_LOGINS_RESTRICTED              => qw(16063);           # mobytrader

sub authorize {
    my $c = shift;

    # APP_ID verification logic
    my ($app_id, $state) = map { defang($c->param($_)) // undef } qw/ app_id state /;

    return $c->_bad_request('the request was missing app_id') unless $app_id;
    return $c->_bad_request('the request was missing valid app_id') if ($app_id !~ /^[0-9]+$/);

    my $oauth_model = _oauth_model();
    my $app         = $oauth_model->verify_app($app_id);

    return $c->_bad_request('the request was missing valid app_id') unless $app;

    # setup oneall callback url
    my $oneall_callback = $c->req->url->path('/oauth2/oneall/callback')->to_abs;
    $c->stash('oneall_callback' => $oneall_callback);

    my $brand_name = BOM::OAuth::Helper->extract_brand_from_params($c->stash('request')->params) // $c->stash('brand')->name;

    # load available networks for brand
    $c->stash('login_providers' => Brands->new(name => $brand_name)->login_providers);

    my ($client, $filtered_clients);
    # try to retrieve client from session
    if (    $c->req->method eq 'POST'
        and ($c->csrf_token eq (defang($c->param('csrf_token')) // ''))
        and defang($c->param('login')))
    {
        $filtered_clients = $c->_login($app) or return;
        $client = $filtered_clients->[0];
        $c->session('_is_logined', 1);
        $c->session('_loginid',    $client->loginid);
    } elsif ($c->req->method eq 'POST' and $c->session('_is_logined')) {
        # Get loginid from Mojo Session
        $filtered_clients = $c->_get_client($app_id);
        $client           = $filtered_clients->[0];
    } elsif ($c->session('_oneall_user_id')) {
        # Get client from Oneall Social Login.
        my $oneall_user_id = $c->session('_oneall_user_id');
        $filtered_clients = $c->_login($app, $oneall_user_id) or return;
        $client = $filtered_clients->[0];
        $c->session('_is_logined', 1);
        $c->session('_loginid',    $client->loginid);
    }

    my %template_params = (
        template                  => _get_login_template_name($brand_name),
        layout                    => $brand_name,
        app                       => $app,
        r                         => $c->stash('request'),
        csrf_token                => $c->csrf_token,
        use_social_login          => $c->_is_social_login_available(),
        login_providers           => $c->stash('login_providers'),
        login_method              => undef,
        is_reset_password_allowed => _is_reset_password_allowed($app->{id}),
        website_domain            => _website_domain($app->{id}),
    );

    my $date_first_contact = $c->param('date_first_contact') // '';
    try {
        return unless $date_first_contact =~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;
        return if Date::Utility->new($date_first_contact)->is_after(Date::Utility->today);
        $c->session(date_first_contact => Date::Utility->new->date_yyyymmdd);
    };

    $c->session(signup_device => $c->param('signup_device')) if ($c->param('signup_device') // '') =~ /^\w+$/;
    # the regexes for the following fields should be the same as new_account_virtual send schema
    $c->session(myaffiliates_token => $c->param('affiliate_token')) if ($c->param('affiliate_token') // '') =~ /^\w{1,32}$/;
    $c->session(gclid_url          => $c->param('gclid_url'))       if ($c->param('gclid_url')       // '') =~ /^[\w\s\.\-_]{1,100}$/;
    $c->session(utm_medium         => $c->param('utm_medium'))      if ($c->param('utm_medium')      // '') =~ /^[\w\s\.\-_]{1,100}$/;
    $c->session(utm_source         => $c->param('utm_source'))      if ($c->param('utm_source')      // '') =~ /^[\w\s\.\-_]{1,100}$/;
    $c->session(utm_campaign       => $c->param('utm_campaign'))    if ($c->param('utm_campaign')    // '') =~ /^[\w\s\.\-_]{1,100}$/;

    # detect and validate social_login param if provided
    if (my $method = $c->param('social_signup')) {
        if (!$c->param('email') and !$c->param('password')) {
            if (_is_social_login_suspended()) {
                _stats_inc_error($brand_name, "TEMP_DISABLED");
                $template_params{error} = localize(get_message_mapping()->{TEMP_DISABLED});
                return $c->render(%template_params);
            }
            if (not grep { $method eq $_ } @{$c->stash('login_providers')}) {
                _stats_inc_error($brand_name, "INVALID_SOCIAL");
                return $c->_bad_request('the request was missing valid social login method');
            }
            $template_params{login_method} = $method;
            return $c->render(%template_params);
        }
    }

    # show error when no client found in session show login form
    if (!$client) {
        $template_params{error}        = delete $c->session->{error}        || '';
        $template_params{social_error} = delete $c->session->{social_error} || '';
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
        _stats_inc_error($brand_name, "TFA_FAILURE");
    }

    # Check if user has enabled 2FA authentication and this is not a scope request
    if ($user->{is_totp_enabled} && !$is_verified) {
        return $c->render(
            template       => $brand_name . '/totp',
            layout         => $brand_name,
            website_domain => _website_domain($app->{id}),
            app            => $app,
            error          => $otp_error,
            r              => $c->stash('request'),
            csrf_token     => $c->csrf_token,
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
            foreach my $c1 (@$filtered_clients) {
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
    $is_all_approved = 1 if grep /^$app_id$/, APPS_ACCESS_PERMISSION_NOT_REQUIRED;
    $is_all_approved ||= $oauth_model->is_scope_confirmed($app_id, $loginid);

    # show scope confirms if not yet approved
    # do not show the scope confirm screen if APP ID is in APPS_ACCESS_PERMISSION_NOT_REQUIRED
    return $c->render(
        template       => $brand_name . '/scope_confirms',
        layout         => $brand_name,
        website_domain => _website_domain($app->{id}),
        app            => $app,
        client         => $client,
        scopes         => \@{$app->{scopes}},
        r              => $c->stash('request'),
        csrf_token     => $c->csrf_token,
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
    foreach my $c1 (@$filtered_clients) {
        my ($access_token) = $oauth_model->store_access_token_only($app_id, $c1->loginid, $ua_fingerprint);
        push @params,
            (
            'acct' . $i  => $c1->loginid,
            'token' . $i => $access_token,
            $c1->default_account ? ('cur' . $i => $c1->default_account->currency_code) : (),
            );
        $i++;
    }

    push @params, (state => $state)
        if defined $state;

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

    my $brand = $c->stash('brand');
    my $brand_name = BOM::OAuth::Helper->extract_brand_from_params($c->stash('request')->params) // $brand->name;

    my $login_details = {
        c              => $c,
        oneall_user_id => $oneall_user_id,
        app_id         => $app->{id}};

    my $result = _validate_login($login_details);

    if (my $err = $result->{error_code}) {
        _stats_inc_error($brand_name, $err);

        $c->render(
            template                  => _get_login_template_name($brand_name),
            layout                    => $brand_name,
            app                       => $app,
            error                     => localize(get_message_mapping()->{$err} // $err),
            r                         => $c->stash('request'),
            csrf_token                => $c->csrf_token,
            use_social_login          => $c->_is_social_login_available(),
            login_providers           => $c->stash('login_providers'),
            login_method              => undef,
            is_reset_password_allowed => _is_reset_password_allowed($app->{id}),
            website_domain            => _website_domain($app->{id}),
        );

        return;
    }

    my $filtered_clients = $result->{filtered_clients};

    # send when client already has login session(s) and its not backoffice (app_id = 4, as we impersonate from backoffice using read only tokens)
    if ($app->{id} ne '4') {

        try {

            # get last login before current login to get last record
            my $client = $filtered_clients->[0];
            my $user   = $result->{user};

            my $last_login = $user->get_last_successful_login_history();

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
                    my $bd   = HTTP::BrowserDetect->new($user_agent);
                    my $tt   = Template->new(ABSOLUTE => 1);
                    my $data = {
                        client_name => $client->first_name ? ' ' . $client->first_name . ' ' . $client->last_name : '',
                        country => $brand->countries_instance->countries->country_from_code($country_code) // $country_code,
                        device  => $bd->device                                                             // $bd->os_string,
                        browser => $bd->browser_string,
                        app     => $app,
                        l       => \&localize
                    };

                    $tt->process('/home/git/regentmarkets/bom-oauth/templates/email/new_signin.html.tt', $data, \my $message);
                    if ($tt->error) {
                        warn "Template error: " . $tt->error;
                        return;
                    }

                    send_email({
                        from                  => $brand->emails('support'),
                        to                    => $client->email,
                        subject               => localize(get_message_mapping()->{NEW_SIGNIN_SUBJECT}),
                        message               => [$message],
                        use_email_template    => 1,
                        email_content_is_html => 1,
                        template_loginid      => $client->loginid,
                        skip_text2html        => 1
                    });
                }
            }
        };
    }

    # reset csrf_token
    delete $c->session->{csrf_token};
    return $filtered_clients;
}

# fetch social login feature status from settings
sub _is_social_login_suspended {
    return BOM::Config::Runtime->instance->app_config->system->suspend->social_logins;
}

# determine availability status of social login feature
sub _is_social_login_available {
    my $c = shift;
    return (not _is_social_login_suspended() and scalar @{$c->stash('login_providers')} > 0);
}

sub _oauth_model {
    return BOM::Database::Model::OAuth->new;
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
    my $c      = shift;
    my $app_id = shift;

    my $client = BOM::User::Client->new({
        loginid      => $c->session('_loginid'),
        db_operation => 'replica'
    });
    return [] if $client->status->disabled;

    my @filtered_clients = _filter_user_clients_by_app_id(
        app_id => $app_id,
        user   => $client->user
    );

    return \@filtered_clients;
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
    my $brand_name = shift // 'binary';
    return $brand_name . '/login';
}

sub _stats_inc_error {
    my ($brand_name, $failure_message) = @_;
    stats_inc('login.authorizer.validation_failure', {tags => ["brand:$brand_name", "error:$failure_message"]});
}

sub _is_reset_password_allowed {
    my $app_id = shift;

    die "Invalid application id." unless $app_id;

    return first { $_ == $app_id } APPS_ALLOWED_TO_RESET_PASSWORD;
}

sub _website_domain {
    my $app_id = shift;

    die "Invalid application id." unless $app_id;

    return "binary.me" if $app_id == 15284;

    return "binary.com";
}

=head2 _validate_login

Validate the email and password inputs. Return the user object
and list of associated clients, upon successful validation. Otherwise,
return the error code

=cut

sub _validate_login {
    my ($login_details) = @_;

    my $err_var = sub {
        my ($error_code) = @_;
        return {error_code => $error_code};
    };

    my $c              = delete $login_details->{c};
    my $oneall_user_id = delete $login_details->{oneall_user_id};

    my $email    = lc defang($c->param('email'));
    my $password = $c->param('password');

    my $user;

    if ($oneall_user_id) {

        $user = BOM::User->new(id => $oneall_user_id);
        return $err_var->("INVALID_USER") unless $user;

        $password = '**SOCIAL-LOGIN-ONEALL**';

    } else {

        return $err_var->("INVALID_EMAIL") unless ($email and Email::Valid->address($email));
        return $err_var->("INVALID_PASSWORD") unless $password;

        $user = BOM::User->new(email => $email);

        return $err_var->("USER_NOT_FOUND") unless $user;

        # Prevent login if social signup flag is found.
        # As the main purpose of this controller is to serve
        # clients with email/password only.

        return $err_var->("NO_SOCIAL_SIGNUP") if $user->{has_social_signup};
    }

    if (BOM::Config::Runtime->instance->app_config->system->suspend->all_logins) {

        BOM::User::AuditLog::log('system suspend all login', $user->{email});
        return $err_var->("TEMP_DISABLED");

    }

    my $result = $user->login(
        password        => $password,
        environment     => $c->_login_env(),
        is_social_login => $oneall_user_id ? 1 : 0,
    );

    return $err_var->($result->{error}) if exists $result->{error};

    my @filtered_clients = _filter_user_clients_by_app_id(
        app_id => $login_details->{app_id},
        user   => $user
    );

    return $err_var->("UNAUTHORIZED_ACCESS") unless @filtered_clients;

    my $client = $filtered_clients[0];

    return $err_var->("TEMP_DISABLED") if grep { $client->loginid =~ /^$_/ } @{BOM::Config::Runtime->instance->app_config->system->suspend->logins};
    return $err_var->("DISABLED") if ($client->status->is_login_disallowed or $client->status->disabled);

    return {
        filtered_clients => \@filtered_clients,
        user             => $user
    };
}

# TODO: Remove this when we agree to use all accounts for Mobytrader
# Currently for soft launch we will just restrict to CR USD
# hence this quick way
sub _filter_user_clients_by_app_id {
    my (%args) = @_;

    my $app_id = $args{app_id};
    my $user   = $args{user};

    return $user->clients unless first { $_ == $app_id } APPS_LOGINS_RESTRICTED;

    return grep { $_ and $_->account and ($_->account->currency_code() // '') eq 'USD' } $user->clients_for_landing_company('svg');
}

1;
