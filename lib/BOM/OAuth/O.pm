package BOM::OAuth::O;

use strict;
use warnings;

no indirect;

use Mojo::Base 'Mojolicious::Controller';
use Date::Utility;
use Syntax::Keyword::Try;
use Digest::MD5 qw(md5_hex);
use Email::Valid;
use List::Util qw(any first min);
use HTML::Entities;
use Format::Util::Strings qw( defang );
use Text::Trim;
use DataDog::DogStatsd::Helper qw(stats_inc);
use HTTP::BrowserDetect;

use Brands;
use LandingCompany::Registry;

use BOM::Config::Runtime;
use BOM::Config::Redis;
use BOM::User;
use BOM::User::Client;
use BOM::User::TOTP;
use BOM::Platform::Email qw(send_email);
use BOM::Database::Model::OAuth;
use BOM::OAuth::Helper;
use BOM::User::AuditLog;
use BOM::Platform::Context qw(localize request);
use BOM::OAuth::Static qw(get_message_mapping);

use Log::Any qw($log);

use constant APPS_LOGINS_RESTRICTED => qw(16063);    # mobytrader

# Time in seconds we'll start blocking someone for repeated bad logins from the same IP
use constant BLOCK_MIN_DURATION => 5 * 60;
# Upper limit in seconds we'll block an IP  for
use constant BLOCK_MAX_DURATION => 24 * 60 * 60;
# How long in seconds before we reset (expire) the exponential backoff
use constant BLOCK_TTL_RESET_AFTER => 24 * 60 * 60;
# How many failed attempts (not necessarily consecutive) before we block this IP
use constant BLOCK_TRIGGER_COUNT => 10;
# How much time in seconds with no failed attempts before we reset (expire) the failure count
use constant BLOCK_TRIGGER_WINDOW => 5 * 60;

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
    my $oneall_callback = Mojo::URL->new($c->req->url->path('/oauth2/oneall/callback')->to_abs);
    $oneall_callback->scheme('https');
    $c->stash('oneall_callback' => $oneall_callback);

    # load available networks for brand
    $c->stash('login_providers' => $c->stash('brand')->login_providers);

    my $r          = $c->stash('request');
    my $brand_name = $c->stash('brand')->name;

    my %template_params = (
        template                  => $c->_get_template_name('login'),
        layout                    => $brand_name,
        app                       => $app,
        r                         => $r,
        csrf_token                => $c->csrf_token,
        use_social_login          => $c->_is_social_login_available(),
        login_providers           => $c->stash('login_providers'),
        login_method              => undef,
        is_reset_password_allowed => _is_reset_password_allowed($app->{id}),
        website_domain            => $c->_website_domain($app->{id}),
    );

    # Check for blocked IPs early in the process.
    my $ip    = $r->client_ip || '';
    my $redis = BOM::Config::Redis::redis_auth();
    if ($ip and $redis->get('oauth::blocked_by_ip::' . $ip)) {
        stats_inc('login.authorizer.block.hit');
        $template_params{error} = localize(get_message_mapping()->{SUSPICIOUS_BLOCKED});
        return $c->render(%template_params);
    }

    my ($client, $filtered_clients);
    # try to retrieve client from session
    if (    $c->req->method eq 'POST'
        and ($c->csrf_token eq (defang($c->param('csrf_token')) // ''))
        and defang($c->param('login')))
    {
        my $login = $c->_login($app) or return;
        $filtered_clients = $login->{filtered_clients};
        $client           = $filtered_clients->[0];
        $c->session('_is_logged_in', 1);
        $c->session('_loginid',      $client->loginid);
        $c->session('_self_closed',  $login->{login_result}->{self_closed});
    } elsif ($c->req->method eq 'POST' and $c->session('_is_logged_in')) {

        # Get loginid from Mojo Session
        $filtered_clients = $c->_get_client($app_id);
        $client           = $filtered_clients->[0];
    } elsif ($c->session('_oneall_user_id')) {

        # Get client from Oneall Social Login.
        my $oneall_user_id = $c->session('_oneall_user_id');
        my $login          = $c->_login($app, $oneall_user_id) or return;
        $filtered_clients = $login->{filtered_clients};
        $client           = $filtered_clients->[0];
        $c->session('_is_logged_in', 1);
        $c->session('_loginid',      $client->loginid);
        $c->session('_self_closed',  $login->{login_result}->{self_closed});
    }

    my $date_first_contact = $c->param('date_first_contact') // '';
    eval {
        return unless $date_first_contact =~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;
        my $date = Date::Utility->new($date_first_contact);
        return if $date->is_after(Date::Utility->today);
        $c->session(date_first_contact => $date->date_yyyymmdd);
    };
    $c->session(signup_device => $c->param('signup_device')) if ($c->param('signup_device') // '') =~ /^\w+$/;
    # the regexes for the following fields should be the same as new_account_virtual send schema
    $c->session(myaffiliates_token => $c->param('affiliate_token'))  if ($c->param('affiliate_token')  // '') =~ /^[\w\-]{1,32}$/;
    $c->session(gclid_url          => $c->param('gclid_url'))        if ($c->param('gclid_url')        // '') =~ /^[\w\s\.\-_]{1,100}$/;
    $c->session(utm_medium         => $c->param('utm_medium'))       if ($c->param('utm_medium')       // '') =~ /^[\w\s\.\-_]{1,100}$/;
    $c->session(utm_source         => $c->param('utm_source'))       if ($c->param('utm_source')       // '') =~ /^[\w\s\.\-_]{1,100}$/;
    $c->session(utm_campaign       => $c->param('utm_campaign'))     if ($c->param('utm_campaign')     // '') =~ /^[\w\s\.\-_]{1,100}$/;
    $c->session(utm_ad_id          => $c->param('utm_ad_id'))        if ($c->param('utm_ad_id')        // '') =~ /^[\w\s\.\-_]{1,100}$/;
    $c->session(utm_adgroup_id     => $c->param('utm_adgroup_id'))   if ($c->param('utm_adgroup_id')   // '') =~ /^[\w\s\.\-_]{1,100}$/;
    $c->session(utm_adrollclk_id   => $c->param('utm_adrollclk_id')) if ($c->param('utm_adrollclk_id') // '') =~ /^[\w\s\.\-_]{1,100}$/;
    $c->session(utm_campaign_id    => $c->param('utm_campaign_id'))  if ($c->param('utm_campaign_id')  // '') =~ /^[\w\s\.\-_]{1,100}$/;
    $c->session(utm_content        => $c->param('utm_content'))      if ($c->param('utm_content')      // '') =~ /^[\w\s\.\-_]{1,100}$/;
    $c->session(utm_fbcl_id        => $c->param('utm_fbcl_id'))      if ($c->param('utm_fbcl_id')      // '') =~ /^[\w\s\.\-_]{1,100}$/;
    $c->session(utm_gl_client_id   => $c->param('utm_gl_client_id')) if ($c->param('utm_gl_client_id') // '') =~ /^[\w\s\.\-_]{1,100}$/;
    $c->session(utm_msclk_id       => $c->param('utm_msclk_id'))     if ($c->param('utm_msclk_id')     // '') =~ /^[\w\s\.\-_]{1,100}$/;
    $c->session(utm_term           => $c->param('utm_term'))         if ($c->param('utm_term')         // '') =~ /^[\w\s\.\-_]{1,100}$/;

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
    my $otp_error   = '';
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
        _failed_login_attempt($c) unless $is_verified;
    }

    # Check if user has enabled 2FA authentication and this is not a scope request
    if ($user->{is_totp_enabled} && !$is_verified) {
        return $c->render(
            template       => $c->_get_template_name('totp'),
            layout         => $brand_name,
            website_domain => $c->_website_domain($app->{id}),
            app            => $app,
            error          => $otp_error,
            r              => $c->stash('request'),
            csrf_token     => $c->csrf_token,
        );
    }

    if ($c->session->{_self_closed}) {
        my $result = $c->_handle_self_closed($filtered_clients, $app, $state);
        return $result if $result;
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
    $is_all_approved = 1 if $oauth_model->is_official_app($app_id);
    $is_all_approved ||= $oauth_model->is_scope_confirmed($app_id, $loginid);

    # show scope confirms if not yet approved
    # do not show the scope confirm screen if APP ID is a primary official app
    return $c->render(
        template       => $c->_get_template_name('scope_confirms'),
        layout         => $brand_name,
        website_domain => $c->_website_domain($app->{id}),
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

    if (my $nonce = $c->session('_sso_nonce')) {
        push @params, (nonce => $nonce);
    }

    $uri->query(\@params);

    stats_inc('login.authorizer.success', {tags => ["brand:$brand_name", "two_factor_auth:$is_verified"]});

    # clear login session
    delete $c->session->{_is_logged_in};
    delete $c->session->{_loginid};
    delete $c->session->{_oneall_user_id};
    delete $c->session->{_otp_verified};

    $c->session(expires => 1);

    $c->redirect_to($uri);
}

=head2 _handle_self_closed

Handles the authorization of self-closed accounts. It returns null if it can reactivate
the self-closed accounts, otherwise returns navigating to confirmation or redirect page.

Arguments:

=over 1

=item C<$clients>

A list of self-closed clients associated with the currently processed credentials.

=item C<$app>

The requested application. 

=item C<$state>

The state parameter of the request.

=back

=cut

sub _handle_self_closed {
    my ($c, $clients, $app, $state) = @_;

    return unless $c->session->{_self_closed};

    my @closed_clients = grep { $_->status->closed } @$clients;

    return unless @closed_clients;

    if (!($c->param('cancel_reactivate') || $c->param('confirm_reactivate'))) {
        my $financial_reasons =
            any { lc($_->status->closed->{reason} // '') =~ 'financial concerns|i have other financial priorities' } @closed_clients;

        my $brand = $c->stash('brand');
        return $c->render(
            template          => $c->_get_template_name('reactivate-acc'),
            layout            => $brand->name,
            app               => $app,
            r                 => $c->stash('request'),
            resp_trading_url  => $brand->responsible_trading_url,
            csrf_token        => $c->csrf_token,
            website_domain    => $c->_website_domain($app->{id}),
            financial_reasons => $financial_reasons,
        );
    }

    delete $c->session->{_self_closed};

    if ($c->param('cancel_reactivate')) {
        # clear session for oneall login when reactivation is canceled
        delete $c->session->{_oneall_user_id};
        delete $c->session->{_otp_verified};

        my $uri = Mojo::URL->new($app->{redirect_uri});
        $uri .= '#error=reactivation_cancelled';
        $uri .= '&state=' . $state if defined $state;

        return $c->redirect_to($uri);
    }

    $c->_activate_accounts(\@closed_clients, $app);

    return undef;
}

=head2 _activate_accounts

Reactivates self-closed accounts of a user and sends email to client on each reactivated account.

Arguments:

=over 4

=item C<closed_clients>

An array-ref containing self-closed sibling accounts which are about to be reactivated.

=item C<app>

The db row representing the requested application.

=back

=cut

sub _activate_accounts {
    my ($c, $closed_clients, $app) = @_;
    my $brand = $c->stash('brand');

    # pick one of the activated siblings by the following order of priority:
    # - social responsibility check is reqired (MLT and MX)
    # - real account with fiat currency
    # - real account with crypto currency
    my $selected_account = (first { $_->landing_company->social_responsibility_check_required } @$closed_clients)
        // (first { !$_->is_virtual && LandingCompany::Registry::get_currency_type($_->currency) eq 'fiat' } @$closed_clients)
        // (first { !$_->is_virtual } @$closed_clients) // $closed_clients->[0];

    my $reason = $selected_account->status->closed->{reason} // '';

    $_->status->clear_disabled for @$closed_clients;

    send_email({
            to            => $brand->emails('social_responsibility'),
            from          => $brand->emails('no-reply'),
            subject       => $selected_account->loginid . ' has been reactivated',
            template_name => 'account_reactivated_sr',
            template_args => {
                loginid => $selected_account->loginid,
                email   => $selected_account->email,
                reason  => $reason,
            },
            use_email_template    => 1,
            email_content_is_html => 1,
            use_event             => 1
        }) if $selected_account->landing_company->social_responsibility_check_required;

    send_email({
            to            => $selected_account->email,
            from          => $brand->emails('no-reply'),
            subject       => localize(get_message_mapping()->{REACTIVATE_EMAIL_SUBJECT}),
            template_name => 'account_reactivated',
            template_args => {
                loginid          => $selected_account->loginid,
                needs_poi        => $selected_account->needs_poi_verification(),
                profile_url      => $brand->profile_url,
                resp_trading_url => $brand->responsible_trading_url,
                live_chat_url    => $brand->live_chat_url,
            },
            template_loginid      => $selected_account->loginid,
            use_email_template    => 1,
            email_content_is_html => 1,
            use_event             => 1
        });

    my $environment      = request()->login_env({user_agent => $c->req->headers->header('User-Agent')});
    my $unknown_location = !$selected_account->user->logged_in_before_from_same_location($environment);

    # perform postponed logging and notification
    $selected_account->user->after_login(undef, $environment, $app->{id}, @$closed_clients);
    $c->c($selected_account, $unknown_location, $app);
}

sub _login {
    my ($c, $app, $oneall_user_id) = @_;

    my $brand_name = $c->stash('brand')->name;

    my $result = _validate_login({
        c              => $c,
        oneall_user_id => $oneall_user_id,
        app            => $app
    });

    if (my $err = $result->{error_code}) {
        _stats_inc_error($brand_name, $err);
        _failed_login_attempt($c);

        my $id = $app->{id};

        $c->render(
            template                  => $c->_get_template_name('login'),
            layout                    => $brand_name,
            app                       => $app,
            error                     => localize(get_message_mapping()->{$err} // $err),
            r                         => $c->stash('request'),
            csrf_token                => $c->csrf_token,
            use_social_login          => $c->_is_social_login_available(),
            login_providers           => $c->stash('login_providers'),
            login_method              => undef,
            is_reset_password_allowed => _is_reset_password_allowed($id),
            website_domain            => $c->_website_domain($id),
        );

        return;
    }

    # reset csrf_token
    delete $c->session->{csrf_token};
    return $result;
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

sub _get_client {
    my $c      = shift;
    my $app_id = shift;

    my $client = BOM::User::Client->new({
        loginid      => $c->session('_loginid'),
        db_operation => 'replica'
    });

    return [] if $client->status->disabled && !$c->session->{_self_closed};

    my @filtered_clients = _filter_user_clients_by_app_id(
        app_id              => $app_id,
        user                => $client->user,
        include_self_closed => $c->session->{_self_closed},

    );

    return \@filtered_clients;
}

sub _bad_request {
    my ($c, $error) = @_;

    return $c->throw_error('invalid_request', $error);
}

=head2 _get_details_from_environment

Get details from environment, which includes the IP address, country, and the
user agent.

=cut

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

sub _get_template_name {
    my ($c, $template_name) = @_;

    return $c->stash('brand')->name . '/' . $template_name;
}

sub _stats_inc_error {
    my ($brand_name, $failure_message) = @_;
    stats_inc('login.authorizer.validation_failure', {tags => ["brand:$brand_name", "error:$failure_message"]});
}

sub _is_reset_password_allowed {
    my $app_id = shift;

    die "Invalid application id." unless $app_id;

    return _oauth_model()->is_primary_website($app_id);
}

sub _website_domain {
    my ($c, $app_id) = @_;

    die "Invalid application id." unless $app_id;

    return 'binary.me' if $app_id == 15284;

    return lc $c->stash('brand')->website_name;
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
    my $app            = delete $login_details->{app};

    my $app_id = $app->{id};

    my $email    = trim(lc defang($c->param('email')));
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

        return $err_var->("LOGIN_ERROR") unless $user;

        # Prevent login if social signup flag is found.
        # As the main purpose of this controller is to serve
        # clients with email/password only.

        return $err_var->("LOGIN_ERROR") if $user->{has_social_signup};
    }

    if (BOM::Config::Runtime->instance->app_config->system->suspend->all_logins) {

        BOM::User::AuditLog::log('system suspend all login', $user->{email});
        return $err_var->("TEMP_DISABLED");
    }

    my $new_env          = request()->login_env({user_agent => $c->req->headers->header('User-Agent')});
    my $unknown_location = !$user->logged_in_before_from_same_location($new_env);

    my $result = $user->login(
        password        => $password,
        environment     => $new_env,
        is_social_login => $oneall_user_id ? 1 : 0,
        app_id          => $app_id
    );

    # Self-closed error is treated like a success; we'll try to reactivate accounts.
    if (($result->{error_code} // '') eq 'AccountSelfClosed') {
        $result = {
            success     => 1,
            self_closed => 1,
        };
    }

    return $err_var->($result->{error}) if exists $result->{error};

    my @filtered_clients = _filter_user_clients_by_app_id(
        app_id              => $app_id,
        user                => $user,
        include_self_closed => $result->{self_closed},
    );

    return $err_var->("UNAUTHORIZED_ACCESS") unless @filtered_clients;

    my $client = $filtered_clients[0];

    return $err_var->("TEMP_DISABLED") if grep { $client->loginid =~ /^$_/ } @{BOM::Config::Runtime->instance->app_config->system->suspend->logins};

    my $client_is_disabled = $client->status->disabled && !($result->{self_closed} && $client->status->closed);
    return $err_var->("DISABLED") if ($client->status->is_login_disallowed or $client_is_disabled);

    # For self-closed accounts the following step is postponed until reactivation is finalized.
    $c->_notify_login($client, $unknown_location, $app) unless $result->{self_closed};

    return {
        filtered_clients => \@filtered_clients,
        user             => $user,
        login_result     => $result,
    };
}

=head2 _notify_login

Tracks the login event and notifies client about successful login form a new (unknown) location.

=cut

sub _notify_login {
    my ($c, $client, $unknown_location, $app) = @_;

    my $bd           = HTTP::BrowserDetect->new($c->req->headers->header('User-Agent'));
    my $country_code = uc($c->stash('request')->country_code // '');
    my $brand        = $c->stash('brand');
    my $request      = $c->stash('request');
    my $ip           = $request->client_ip || '';

    if (!$c->session('_is_social_signup')) {
        BOM::Platform::Event::Emitter::emit(
            'login',
            {
                loginid    => $client->loginid,
                properties => {
                    ip                  => $ip,
                    location            => $brand->countries_instance->countries->country_from_code($country_code) // $country_code,
                    browser             => $bd->browser,
                    device              => $bd->device // $bd->os_string,
                    new_signin_activity => $unknown_location ? 1 : 0,
                }});
    }

    if ($unknown_location && $brand->send_signin_email_enabled()) {
        my $email_data = {
            client_name => $client->first_name
            ? ' ' . $client->first_name . ' ' . $client->last_name
            : '',
            country => $brand->countries_instance->countries->country_from_code($country_code) // $country_code,
            device  => $bd->device                                                             // $bd->os_string,
            browser => $bd->browser_string                                                     // $bd->browser,
            app     => $app,
            ip      => $ip,
            language                  => lc($request->language),
            start_url                 => 'https://' . lc($brand->website_name),
            is_reset_password_allowed => _is_reset_password_allowed($app->{id}),
        };

        send_email({
            to                    => $client->email,
            subject               => localize(get_message_mapping()->{NEW_SIGNIN_SUBJECT}),
            template_name         => 'unknown_login',
            template_args         => $email_data,
            template_loginid      => $client->loginid,
            use_email_template    => 1,
            email_content_is_html => 1,
            use_event             => 1
        });
    }
}

# TODO: Remove this when we agree to use all accounts for Mobytrader
# Currently for soft launch we will just restrict to CR USD
# hence this quick way
sub _filter_user_clients_by_app_id {
    my (%args) = @_;

    my $app_id = delete $args{app_id};
    my $user   = delete $args{user};

    return $user->clients(%args) unless first { $_ == $app_id } APPS_LOGINS_RESTRICTED;

    return grep { $_ and $_->account and ($_->account->currency_code() // '') eq 'USD' } $user->clients_for_landing_company('svg');
}

=head2 _failed_login_attempt

Called for failed manual login attempt.
Increments redis counts and may set a blocking flag.

=cut

sub _failed_login_attempt {
    my $c = shift;

    stats_inc('login.authorizer.login_failed');

    # Something went wrong - most probably login failure. Innocent enough in isolation;
    # if we see a pattern of failures from the same address, we would want to discourage
    # further attempts.
    my $ip = $c->stash('request')->client_ip;
    if ($ip) {
        try {
            my $redis = BOM::Config::Redis::redis_auth_write();
            my $k     = 'oauth::failure_count_by_ip::' . $ip;
            if ($redis->incr($k) > BLOCK_TRIGGER_COUNT) {
                # Note that we don't actively delete the failure count here, since we expect
                # it to expire before the block does. If it doesn't... well, this only applies
                # on failed login attempt, if you get the password right first time after the
                # block then you're home free.

                my $ttl = $redis->get('oauth::backoff_by_ip::' . $ip);
                $ttl = min(BLOCK_MAX_DURATION, $ttl ? $ttl * 2 : BLOCK_MIN_DURATION);
                $log->infof('Multiple login failures from the same IP %s, blocking for %d seconds', $ip, $ttl);

                # Record our new TTL (hangs around for a day, which we expect to be sufficient
                # to slow down offenders enough that we no longer have to be particularly concerned),
                # and also apply the block at this stage.
                $redis->set('oauth::backoff_by_ip::' . $ip, $ttl, EX => BLOCK_TTL_RESET_AFTER);
                $redis->set('oauth::blocked_by_ip::' . $ip, 1,    EX => $ttl);
                stats_inc('login.authorizer.block.add');
            } else {
                # Extend expiry every time there's a failure
                $redis->expire($k, BLOCK_TRIGGER_WINDOW);
                stats_inc('login.authorizer.block.fail');
            }
        } catch ($err) {
            $log->errorf('Failure encountered while handling Redis blocklists for failed login: %s', $err);
            stats_inc('login.authorizer.block.error');
        }
    }

}

1;
