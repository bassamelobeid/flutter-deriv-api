package BOM::OAuth::O;

use strict;
use warnings;

no indirect;

use DataDog::DogStatsd::Helper qw( stats_inc );
use Date::Utility;
use Digest::MD5 qw( md5_hex );
use Email::Valid;
use Format::Util::Strings qw( defang );
use HTML::Entities;
use HTTP::BrowserDetect;
use List::Util qw( any first min );
use Log::Any qw( $log );
use Mojo::Base 'Mojolicious::Controller';
use Syntax::Keyword::Try;
use Text::Trim;

use Brands;
use LandingCompany::Registry;

use BOM::Config::Redis;
use BOM::Config::Runtime;
use BOM::Database::Model::OAuth;
use BOM::User;
use BOM::User::Client;
use BOM::User::TOTP;
use BOM::OAuth::Common;
use BOM::OAuth::Helper;
use BOM::OAuth::Static qw(get_message_mapping);
use BOM::Platform::Context qw(localize request);
use BOM::Platform::Email qw(send_email);
use BOM::User::AuditLog;

sub authorize {
    my $c = shift;
    # APP_ID verification logic
    my ($app_id, $state) = map { defang($c->param($_)) // undef } qw/ app_id state /;

    return $c->_bad_request('the request was missing app_id') unless $app_id;
    return $c->_bad_request('the request was missing valid app_id') if ($app_id !~ /^[0-9]+$/);

    my $oauth_model = BOM::Database::Model::OAuth->new;
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
        is_reset_password_allowed => BOM::OAuth::Common::is_reset_password_allowed($app->{id}),
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

    my ($client, $clients);
    # try to retrieve client from session
    if (    $c->req->method eq 'POST'
        and ($c->csrf_token eq (defang($c->param('csrf_token')) // ''))
        and defang($c->param('login')))
    {
        my $login = $c->_login($app) or return;
        $clients = $login->{clients};
        $client  = $clients->[0];
        $c->session('_is_logged_in', 1);
        $c->session('_loginid',      $client->loginid);
        $c->session('_self_closed',  $login->{login_result}->{self_closed});
    } elsif ($c->req->method eq 'POST' and $c->session('_is_logged_in')) {

        # Get loginid from Mojo Session
        $clients = $c->_get_client($app_id);
        $client  = $clients->[0];
    } elsif ($c->session('_oneall_user_id')) {

        # Get client from Oneall Social Login.
        my $oneall_user_id = $c->session('_oneall_user_id');
        my $login          = $c->_login($app, $oneall_user_id) or return;
        $clients = $login->{clients};
        $client  = $clients->[0];
        $c->session('_is_logged_in', 1);
        $c->session('_loginid',      $client->loginid);
        $c->session('_self_closed',  $login->{login_result}->{self_closed});
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
        BOM::OAuth::Common::failed_login_attempt($c) unless $is_verified;
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
            # approval on all loginids
            foreach my $c1 (@$clients) {
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
    my $client_ip     = $c->client_ip;
    my $client_params = {
        clients => $clients,
        ip      => $client_ip,
        app_id  => $app_id,
    };
    my @params = BOM::OAuth::Common::generate_url_token_params($c, $client_params);

    push @params, (state => $state)
        if defined $state;

    if (my $nonce = $c->session('_sso_nonce')) {
        push @params, (nonce => $nonce);
    }

    stats_inc('login.authorizer.success', {tags => ["brand:$brand_name", "two_factor_auth:$is_verified"]});

    # clear login session
    delete $c->session->{_is_logged_in};
    delete $c->session->{_loginid};
    delete $c->session->{_oneall_user_id};
    delete $c->session->{_otp_verified};

    $c->session(expires => 1);

    return BOM::OAuth::Common::redirect_to($c, $redirect_uri, \@params);
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

    return undef;    ## no critic (ProhibitExplicitReturnUndef)
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

    # pick one of the activated siblings by the following order of priority:
    # - social responsibility check is reqired (MLT and MX)
    # - real account with fiat currency
    # - real account with crypto currency
    my $selected_account = (first { $_->landing_company->social_responsibility_check_required } @$closed_clients)
        // (first { !$_->is_virtual && LandingCompany::Registry::get_currency_type($_->currency) eq 'fiat' } @$closed_clients)
        // (first { !$_->is_virtual } @$closed_clients) // $closed_clients->[0];

    my $reason = $selected_account->status->closed->{reason} // '';
    $_->status->clear_disabled for @$closed_clients;

    BOM::Platform::Event::Emitter::emit(
        'account_reactivated',
        {
            loginid        => $selected_account->loginid,
            closure_reason => $reason
        });

    my $environment      = request()->login_env({user_agent => $c->req->headers->header('User-Agent')});
    my $unknown_location = !$selected_account->user->logged_in_before_from_same_location($environment);

    # perform postponed logging and notification
    $selected_account->user->after_login(undef, $environment, $app->{id}, @$closed_clients);
    $c->c($selected_account, $unknown_location, $app);
}

sub _login {
    my ($c, $app, $oneall_user_id) = @_;

    my $email    = trim lc(defang $c->param('email'));
    my $password = $c->param('password');

    my $brand_name = $c->stash('brand')->name;

    my $result = BOM::OAuth::Common::validate_login({
        c              => $c,
        app            => $app,
        oneall_user_id => $oneall_user_id,
        email          => $email,
        password       => $password,
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
            use_social_login          => $c->_is_social_login_available(),
            login_providers           => $c->stash('login_providers'),
            login_method              => undef,
            is_reset_password_allowed => BOM::OAuth::Common::is_reset_password_allowed($id),
            website_domain            => $c->_website_domain($id),
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

sub _website_domain {
    my ($c, $app_id) = @_;

    die "Invalid application id." unless $app_id;

    return 'binary.me' if $app_id == 15284;
    return 'deriv.me'  if $app_id == 1411;

    return lc $c->stash('brand')->website_name;
}

1;
