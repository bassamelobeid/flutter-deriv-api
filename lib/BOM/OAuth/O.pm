package BOM::OAuth::O;

use strict;
use warnings;

no indirect;

use Array::Utils               qw(array_diff);
use DataDog::DogStatsd::Helper qw( stats_inc );
use Date::Utility;
use Digest::MD5 qw( md5_hex );
use Email::Valid;
use Format::Util::Strings qw( defang );
use HTML::Entities;
use HTTP::BrowserDetect;
use List::Util qw( any first min );
use Log::Any   qw( $log );
use Mojo::Base 'Mojolicious::Controller';
use Syntax::Keyword::Try;
use Text::Trim;

use Brands;
use LandingCompany::Registry;

use BOM::Config;
use BOM::Config::Redis;
use BOM::Config::Runtime;
use BOM::Database::Model::OAuth;
use BOM::User;
use BOM::User::Client;
use BOM::User::TOTP;
use BOM::OAuth::Common;
use BOM::OAuth::Helper     qw(request_details_string exception_string build_signup_url);
use BOM::OAuth::Static     qw(get_message_mapping);
use BOM::Platform::Context qw(localize request);
use BOM::Platform::Email   qw(send_email);
use BOM::User::AuditLog;
use URI::Escape;
use BOM::OAuth::SocialLoginClient;
use BOM::OAuth::Passkeys::PasskeysService;
use constant CTRADER_APPID => 36218;

sub authorize {
    my $c = shift;
    # specify caching directives for the browser
    $c->res->headers->cache_control('no-store, no-cache, must-revalidate, max-age=0');
    $c->res->headers->expires('0');

    # Prevent the page from being controlled by a parent window to mitigate cross-windows attacks.
    $c->res->headers->header('Cross-Origin-Opener-Policy' => 'same-origin');

    # APP_ID verification logic
    my ($app_id, $state) = map { defang($c->param($_)) // undef } qw/ app_id state /;

    return $c->_bad_request('the request was missing app_id') unless $app_id;
    return $c->_bad_request('the request was missing valid app_id') if ($app_id !~ /^[0-9]+$/);

    my $social_login_bypass = 0;
    if ($app_id == CTRADER_APPID) {
        $c->app->sessions->secure(1);
        $c->app->sessions->samesite('None');
        $c->res->headers->header('Content-Security-Policy' => join(" ", 'frame-ancestors', 'https://ct-uat.deriv.com/', 'https://ct.deriv.com/'));
        $social_login_bypass = 1;
    }

    my $oauth_model = BOM::Database::Model::OAuth->new;
    my $app         = $oauth_model->verify_app($app_id);

    return $c->_bad_request('the request was missing valid app_id') unless $app;

    # setup oneall callback url
    my $oneall_callback = Mojo::URL->new($c->req->url->path('/oauth2/oneall/callback')->to_abs);
    $oneall_callback->scheme('https');
    $c->stash('oneall_callback' => $oneall_callback);

    # Setup Social Login
    try {
        BOM::OAuth::Helper::setup_social_login($c);
    } catch ($e) {
        $log->errorf("Error while setup social login links: %s - %s",
            exception_string($e), request_details_string($c->req, $c->stash('request_details')));
    }

    # load available networks for brand
    $c->stash('login_providers' => $c->stash('brand')->login_providers);

    my $r          = $c->stash('request');
    my $brand_name = $c->stash('brand')->name;

    my $lang = lc(defang($c->stash('request')->language) // 'en');
    $lang =~ s/_/-/;    # for cases like zh_cn, zh_tw

    my $partnerId = (defined $c->param('partnerId') && $c->param('partnerId') =~ /^[\w\-]{1,32}$/) ? defang($c->param('partnerId')) : '';

    my $params_signup_url = {
        app_id    => $app_id,
        lang      => $lang,
        partnerId => $partnerId
    };

    my %template_params = (
        template                  => $c->_get_template_name('login'),
        layout                    => $brand_name,
        app                       => $app,
        r                         => $r,
        csrf_token                => $c->csrf_token,
        use_social_login          => $social_login_bypass ? 0 : $c->_is_social_login_available(),
        login_providers           => $c->stash('login_providers'),
        login_method              => undef,
        is_reset_password_allowed => BOM::OAuth::Common::is_reset_password_allowed($app->{id}),
        social_login_links        => $c->stash('social_login_links'),
        use_oneall                => $c->_use_oneall_web,
        growthbook_request_data   => _get_growthbook_config(),
        user_request_details      => JSON::MaybeXS->new->utf8->encode($c->stash('request_details')),
        dd_rum_config             => _datadog_config(),
        signup_url                => build_signup_url($params_signup_url),
    );

    try {
        $template_params{website_domain} = $c->_website_domain($app->{id});

        # Check for blocked IPs early in the process.
        my $ip    = $r->client_ip || '';
        my $redis = BOM::Config::Redis::redis_auth();
        if ($ip and $redis->get('oauth::blocked_by_ip::' . $ip)) {
            stats_inc('login.authorizer.block.hit');
            $template_params{error} = localize(get_message_mapping()->{SUSPICIOUS_BLOCKED});
            return $c->render(%template_params);
        }

        my ($client, $clients);
        my $login_type = $c->_get_login_type;
        # try to retrieve client from session
        if ($login_type eq 'basic') {
            my $login = $c->_login({app => $app, social_login_bypass => $social_login_bypass, params_signup_url => $params_signup_url}) or return;
            $clients = $login->{clients};
            $client  = $clients->[0];
            $c->set_logged_in_session($client->loginid, $login->{login_result}->{self_closed});
        } elsif ($login_type eq 'session') {
            # Get loginid from Mojo Session
            $clients = $c->_get_client($app_id);
            $client  = $clients->[0];
        } elsif ($login_type eq 'oneall') {

            # Get client from Oneall Social Login.
            my $oneall_user_id = $c->session('_oneall_user_id');
            my $login          = $c->_login({app => $app, oneall_user_id => $oneall_user_id, params_signup_url => $params_signup_url}) or return;
            $clients = $login->{clients};
            $client  = $clients->[0];
            $c->set_logged_in_session($client->loginid, $login->{login_result}->{self_closed});
        } elsif ($login_type eq 'social') {    #exact same logic as oneall
                                               # Get client from sls Social Login.
            my $sls_user_id = $c->session('_sls_user_id');
            my $login       = $c->_login({app => $app, oneall_user_id => $sls_user_id, params_signup_url => $params_signup_url}) or return;
            $clients = $login->{clients};
            $client  = $clients->[0];
            $c->set_logged_in_session($client->loginid, $login->{login_result}->{self_closed});
        } elsif ($login_type eq 'passkeys') {
            my $login = $c->_passkeys_login($app, %template_params) or return;
            $clients = $login->{clients};
            $client  = $clients->[0];
            $c->set_logged_in_session($client->loginid, $login->{login_result}->{self_closed});
        }

        my $date_first_contact = $c->param('date_first_contact') // '';
        eval {    ## no critic (Eval)
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
        $c->session(platform           => $c->param('platform'))         if ($c->param('platform')         // '') =~ /^[\w]{1,100}$/;

        # detect and validate social_login param if provided
        if (my $method = $c->param('social_signup')) {
            if (!$c->param('email') && !$c->param('password')) {
                if (BOM::OAuth::Common::is_social_login_suspended()) {
                    _stats_inc_error($brand_name, "TEMP_DISABLED");
                    $template_params{error} = localize(get_message_mapping()->{TEMP_DISABLED});
                    return $c->render(%template_params);
                }
                if (not grep { $method eq $_ } @{$c->stash('login_providers')}) {
                    _stats_inc_error($brand_name, "INVALID_SOCIAL");
                    return $c->_bad_request('the request was missing valid social login method');
                }

                # Handle sign-up for Social Login service
                unless ($c->_use_oneall_web) {
                    my $provider_link = $c->stash('social_login_links')->{$method};
                    return $c->redirect_to($provider_link) if $provider_link;
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

        my $user = $client->user;

        unless ($user) {
            $template_params{error} = localize(get_message_mapping()->{INVALID_USER});
            return $c->render(%template_params);
        }

        # Let's check the block counter
        if ($redis->get('oauth::blocked_by_user::' . $user->id)) {
            stats_inc('login.authorizer.block.hit');
            $template_params{error} = localize(get_message_mapping()->{SUSPICIOUS_BLOCKED});
            return $c->render(%template_params);
        }

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
            BOM::OAuth::Common::failed_login_attempt($c, $user) unless $is_verified;
        }

        # Check if user has enabled 2FA authentication and this is not a scope request
        # The 2FA check will be skipped for Passkey logins
        if ($user->{is_totp_enabled} && !$is_verified && $login_type ne 'passkeys') {
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
            my $result = $c->_handle_self_closed($clients, $app, $state);
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
                # first, check if the scopes shown to the user haven't changed
                if (_scopes_changed(defang($c->param('confirm_scopes')), $app->{scopes})) {
                    # if the scopes changed, show the scopes again to the user with the updated list
                    return $c->render(
                        template       => $c->_get_template_name('scope_confirms'),
                        layout         => $brand_name,
                        website_domain => $c->_website_domain($app->{id}),
                        app            => $app,
                        client         => $client,
                        scopes         => \@{$app->{scopes}},
                        r              => $c->stash('request'),
                        csrf_token     => $c->csrf_token,
                        scopes_changed => 1
                    );
                } else {
                    # approval on all loginids
                    foreach my $c1 (@$clients) {
                        $is_all_approved = $oauth_model->confirm_scope($app_id, $c1->loginid);
                    }
                }
            } elsif ($c->param('cancel_scopes')) {
                my $uri = Mojo::URL->new($redirect_uri);
                $uri .= '#error=scope_denied';
                $uri .= '&state=' . $state if defined $state;
                # clear session for oneall login when scope is canceled
                delete $c->session->{_oneall_user_id};
                delete $c->session->{_sls_user_id};
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
            scopes_changed => 0
        ) unless $is_all_approved;

        # setting up client ip
        my $client_ip     = $c->client_ip;
        my $client_params = {
            clients => $clients,
            ip      => $client_ip,
            app_id  => $app_id,
        };

        my @params = BOM::OAuth::Common::generate_url_token_params($c, $client_params);

        if (my $route = $c->param('route')) {
            push @params, (route => format_route_param($route));
        }
        push @params, (state => $state)
            if defined $state;

        if (my $nonce = $c->session('_sso_nonce')) {
            push @params, (nonce => $nonce);
        }

        if (my $platform = delete $c->session->{platform}) {
            push @params, (platform => $platform);
        }

        if (my $lang = defang($c->param('l'))) {
            push @params, (lang => uc($lang));
        }

        stats_inc('login.authorizer.success', {tags => ["brand:$brand_name", "two_factor_auth:$is_verified"]});

        # clear login session
        delete $c->session->{_is_logged_in};
        delete $c->session->{_loginid};
        delete $c->session->{_oneall_user_id};
        delete $c->session->{_sls_user_id};
        delete $c->session->{_otp_verified};

        $c->session(expires => 1);
        return BOM::OAuth::Common::redirect_to($c, $redirect_uri, \@params);
    } catch {
        $template_params{error} = localize(get_message_mapping()->{invalid});
        return $c->render(%template_params);
    }
}

=head2 set_logged_in_session

Set the session for the logged in user.

=over 4 

=item C<$c> -The controller object.

=item C<$loginid> -The loginid of the user.

=item C<$is_self_closed> -The self_closed status of the user.

=back

=cut

sub set_logged_in_session {
    my ($c, $loginid, $is_self_closed) = @_;
    $c->session('_is_logged_in', 1);
    $c->session('_loginid',      $loginid);
    $c->session('_self_closed',  $is_self_closed);
}

=head2 _passkeys_login

Handles the passkeys login.

=over 4

=item C<$c> -The controller object.

=item C<$app> -The requested application.

=item C<%template_params> -The template parameters.

=back

=cut

sub _passkeys_login {
    my ($c, $app, %template_params) = @_;
    my $passkeys_user_id;
    try {
        my $passkeys_service      = BOM::OAuth::Passkeys::PasskeysService->new;
        my $passkeys_user_details = $passkeys_service->get_user_details($c->param('publicKeyCredential'), $c->stash('request_details'));
        $passkeys_user_id = $passkeys_user_details->{binary_user_id};
    } catch ($e) {
        $log->errorf("Passkeys login exception - failed to get user info - %s %s", $e->{code}, ($e->{additional_info} // ""));
        $template_params{passkeys_error} = localize(get_message_mapping()->{$e->{code}} // $e->{code});
        $c->render(%template_params);
        return;    # to keep it consistent we need to return undef;
    }
    return $c->_login({app => $app, passkeys_user_id => $passkeys_user_id});
}

=head2 _scopes_changed

Checks if the current app scopes matches the scopes showen to the user.

Arguments:

=over 1

=item C<$user_scopes>

A comma-separated string contains the scopes the user agreed to.

=item C<$app_scopes>

An array ref contains the scopes of the requested application.

=back

=cut

sub _scopes_changed {
    my ($user_scopes, $app_scopes) = @_;

    my @user_scopes_arr = split(',', $user_scopes);

    return array_diff(@user_scopes_arr, @$app_scopes);
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
        delete $c->session->{_sls_user_id};
        delete $c->session->{_otp_verified};

        my $uri = Mojo::URL->new($app->{redirect_uri});
        $uri .= '#error=reactivation_cancelled';
        $uri .= '&state=' . $state if defined $state;

        return $c->redirect_to($uri);
    }

    BOM::OAuth::Common::activate_accounts($c, \@closed_clients, $app);

    return undef;    ## no critic (ProhibitExplicitReturnUndef)
}

sub _login {
    my ($c, $params) = @_;
    my ($app, $oneall_user_id, $social_login_bypass, $passkeys_user_id, $params_signup_url) =
        @{$params}{qw/app oneall_user_id social_login_bypass passkeys_user_id params_signup_url/};

    my $email    = trim lc(defang $c->param('email'));
    my $password = $c->param('password');

    my $brand_name = $c->stash('brand')->name;

    my $result = BOM::OAuth::Common::validate_login({
        c                => $c,
        app              => $app,
        oneall_user_id   => $oneall_user_id,
        passkeys_user_id => $passkeys_user_id,
        email            => $email,
        password         => $password,
        device_id        => $c->req->param('device_id'),
    });

    if ($result->{error_code}) {
        my $err = $result->{error_msg} // $result->{error_code};

        _stats_inc_error($brand_name, $err);
        BOM::OAuth::Common::failed_login_attempt($c);

        my $id = $app->{id};

        $c->render(
            template                  => $c->_get_template_name('login'),
            layout                    => $brand_name,
            app                       => $app,
            error                     => localize(get_message_mapping()->{$err} // $err),
            r                         => $c->stash('request'),
            csrf_token                => $c->csrf_token,
            use_social_login          => $social_login_bypass ? 0 : $c->_is_social_login_available(),
            login_providers           => $c->stash('login_providers'),
            login_method              => undef,
            is_reset_password_allowed => BOM::OAuth::Common::is_reset_password_allowed($id),
            website_domain            => $c->_website_domain($id),
            social_login_links        => $c->stash('social_login_links'),
            use_oneall                => $c->_use_oneall_web,
            email_entered             => $email,
            signup_url                => build_signup_url($params_signup_url),
            growthbook_request_data   => _get_growthbook_config(),
        );

        return;
    }

    # reset csrf_token
    delete $c->session->{csrf_token};
    return $result;
}

# determine availability status of social login feature
sub _is_social_login_available {
    my $c = shift;
    return (not BOM::OAuth::Common::is_social_login_suspended() and scalar @{$c->stash('login_providers')} > 0);
}

=head2 _oneall_ff_web

Get social login feature flag value for web.

=cut

sub _oneall_ff_web {

    return BOM::Config::Runtime->instance->app_config->social_login->use_oneall_web;
}

=head2 _use_oneall_web

determine which service will be used social-login or oneAll based on feature flag;

=cut

sub _use_oneall_web {
    my $c = shift;

    my $use_oneall              = $c->_oneall_ff_web;
    my $query_string_flag_value = $c->req->param('use_service');
    #For AB testing, If we are using OneAll, we can override the value by providing query string param.
    return 0 if $query_string_flag_value;
    return $use_oneall;
}

=head2 _use_oneall_mobile

determine which service will be used by mobile app, social-login or oneAll based on feature flag;

=cut

sub _use_oneall_mobile {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->check_for_update;
    return $app_config->social_login->use_oneall_mobile;
}

sub _get_client {
    my $c = shift;

    my $client = BOM::User::Client->new({
        loginid      => $c->session('_loginid'),
        db_operation => 'replica'
    });

    return [] if $client->status->disabled && !$c->session->{_self_closed};

    my @clients = $client->user->clients(
        include_self_closed => $c->session->{_self_closed},
    );

    return \@clients;
}

sub _bad_request {
    my ($c, $error) = @_;

    $log->warn("Bad Request - $error - " . request_details_string($c->req, $c->stash('request_details')));
    return $c->throw_error('invalid_request', $error);
}

sub _get_template_name {
    my ($c, $template_name) = @_;

    return $c->stash('brand')->name . '/' . $template_name;
}

sub _stats_inc_error {
    my ($brand_name, $failure_message) = @_;
    stats_inc('login.authorizer.validation_failure', {tags => ["brand:$brand_name", "error:$failure_message"]});
}

sub _website_domain {
    my ($c, $app_id) = @_;

    return lc(Brands->new()->website_name // '') unless $app_id;

    return 'binary.me' if $app_id == 15284;
    return 'deriv.me'  if $app_id == 1411;
    return 'deriv.be'  if $app_id == 30767;

    return lc $c->stash('brand')->website_name;
}

sub _datadog_config {
    my $config        = BOM::Config::third_party()->{datadog};
    my $is_production = BOM::Config::on_production;

    return {
        APP_ID              => $config->{oauth_rum_app_id},
        CLIENT_TOKEN        => $config->{oauth_rum_client_token},
        SESSION_SAMPLE_RATE => 10,
        SERVICE_NAME        => 'oauth.deriv.com',
        VERSION             => '1.0',
        ENV                 => $is_production ? 'production' : 'qa',
    };
}

=head2 format_route_param

the route param passed in auth call will be move forward to redirect url as query param

Arguments:

=over 1

=item C<$route_param>

the route param maintaining the previous route before auth call

=back

=cut

sub format_route_param {
    my $route_param = shift;
    $route_param = defined $route_param ? uri_escape($route_param) : "";
    return $route_param;
}

=head2 _get_growthbook_config

Returns the growthbook configuration.

=cut

sub _get_growthbook_config {
    my $growthbook_config = BOM::Config::growthbook_config();

    return {
        IS_ENABLED => $growthbook_config->{is_growthbook_enabled} || 0,
        CLIENT_KEY => $growthbook_config->{growthbook_client_key} || undef,
    };
}

=head2 _is_valid_post_request

Check if the request is a valid POST request. by evaluating the request method and csrf token.

=over 4

=item C<$c> -The controller object.

=back

=cut

sub _is_valid_post_request {
    my $c = shift;
    return (($c->req->method eq 'POST') && ($c->csrf_token eq (defang($c->param('csrf_token')) // '')));
}

# a map of login types and their validation functions.
my $login_types = {
    basic => sub {
        my $c = shift;
        return ($c->_is_valid_post_request && defang($c->param('login')));
    },
    session => sub {
        my $c = shift;
        return ($c->req->method eq 'POST') && $c->session('_is_logged_in');
    },
    oneall => sub {
        my $c = shift;
        return $c->session('_oneall_user_id');
    },
    social => sub {
        my $c = shift;
        return $c->session('_sls_user_id');
    },
    passkeys => sub {
        my $c = shift;
        return ($c->_is_valid_post_request && defang($c->param('passkeys_login')));
    },
};

=head2 _get_login_type

Get the login type from the request. The login type is determined by applying the validation functions in the login_types map.
Returns a string representing the login type. or an empty string if no valid login type is found.

=over 4

=item C<$c> -The controller object.

=back

=cut

sub _get_login_type {
    my $c = shift;
    # the order of login types to be checked.
    my @login_types_order = ('basic', 'session', 'oneall', 'social', 'passkeys');
    for my $type (@login_types_order) {
        if ($login_types->{$type}->($c)) {
            return $type;
        }
    }
    return '';
}

1;
