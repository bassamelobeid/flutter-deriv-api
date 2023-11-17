package BOM::OAuth::SocialLoginController;

use strict;
use warnings;
use Log::Any qw( $log );
use Mojo::Base 'Mojolicious::Controller';
use Syntax::Keyword::Try;
use BOM::OAuth::Helper         qw(request_details_string exception_string social_login_callback_base);
use BOM::OAuth::Static         qw( get_message_mapping );
use BOM::Platform::Context     qw( localize );
use DataDog::DogStatsd::Helper qw( stats_inc );
use Email::Valid;
use BOM::OAuth::Common;
use constant OK_STATUS_CODE => 200;
use BOM::OAuth::SocialLoginClient;
use Locale::Codes::Country qw( code2country );
use BOM::Config;

=head2 redirect_to_auth_page

All flows will end by calling this function.
will redirect to authorize page and populate:
Social_error if any.
Query string parameters with the original ones found when flow intiated /authorize.
Remove query string parameters carried with the callback.

=cut

sub redirect_to_auth_page {
    my ($c, $error_code, @args) = @_;

    if ($error_code) {
        $c->session(social_error => localize(get_message_mapping()->{$error_code}, @args));
        $log->warnf($c->_to_error_message("processing failed with error code $error_code"));
    }
    my $redirect = $c->req->url->path('/oauth2/authorize')->to_abs->scheme('https');
    $c->_populate_redirect_query_params($redirect);
    return $c->redirect_to($redirect);
}

=head2 _populate_redirect_query_params

Populate /authorize redirect query string parameters with the original ones found when flow intiated /authorize.
Remove code, state query strings if presents.
The parameters will be extracted from the stash, which has been extracted from sls_cookie in first place.

=cut 

sub _populate_redirect_query_params {
    my ($c, $redirect) = @_;

    #clear current query_string params.
    for my $key (keys $redirect->query->to_hash->%*) {
        $redirect->query->remove($key);
    }
    #append only required original query parameters.
    for my $key (qw /app_id brand l date_first_contact signup_device/) {
        $redirect->query->append($key => $c->stash('query_params')->{$key});
    }
}

=head2 _extract_request_parametrs

Gather all request info:
Original query string params, provider params From social login cookie (aka sls).
Provider from request path /:sls_provider.
AuthCode, and state from callbak query string parameters.

=cut

sub _extract_request_parametrs {
    my $c      = shift;
    my $cookie = {};
    try {
        $cookie = BOM::OAuth::Helper::get_social_login_cookie($c);
        $cookie->{query_params}->{brand} //= Brands->new(app_id => $cookie->{query_params}->{app_id})->name;    #try using app_id
    } catch ($e) {
        $log->errorf($c->_to_error_message($e));
    }

    my $provider = $c->stash('sls_provider');    #from callback path /callback/sls_provider.
    return {
        provider        => $provider,
        query_params    => $cookie->{query_params}  // {},
        provider_params => $cookie->{$provider}     // {},
        callback_params => $c->req->params->to_hash // {}};
}

=head2 _extract_user_details

Get user additional info from session, statch needed to create user.

=cut

sub _extract_user_details {
    my ($c) = @_;
    my $user_details = {
        residence          => $c->stash('request')->country_code,    # Get client's residence automatically from cloudflare headers
        date_first_contact => $c->session('date_first_contact'),
        signup_device      => $c->session('signup_device'),
        myaffiliates_token => $c->session('myaffiliates_token'),
        gclid_url          => $c->session('gclid_url'),
        utm_medium         => $c->session('utm_medium'),
        utm_source         => $c->session('utm_source'),
        utm_campaign       => $c->session('utm_campaign'),
        source             => $c->stash('query_params')->{app_id},
        brand              => $c->stash('query_params')->{brand}};
    return $user_details;
}

=head2 _extract_utm_details
=cut

sub _extract_utm_details {
    my ($c) = @_;
    return {
        utm_ad_id        => $c->session('utm_ad_id'),
        utm_adgroup_id   => $c->session('utm_adgroup_id'),
        utm_adrollclk_id => $c->session('utm_adrollclk_id'),
        utm_campaign_id  => $c->session('utm_campaign_id'),
        utm_content      => $c->session('utm_content'),
        utm_fbcl_id      => $c->session('utm_fbcl_id'),
        utm_gl_client_id => $c->session('utm_gl_client_id'),
        utm_msclk_id     => $c->session('utm_msclk_id'),
        utm_term         => $c->session('utm_term'),
    };
}

=head2 _is_valid_signin_attempt

Validate the social signin attempt.

=cut 

sub _is_valid_signin_attempt {
    my ($user, $provider_name) = @_;

    die "User is missing" unless $user;

    # Registered users who have email/password based account are forbidden
    # from social signin. As only one login method
    # is allowed (either email/password or social login).
    return {error => 'NO_LOGIN_SIGNUP'} unless $user->{has_social_signup};

    my $user_connect   = BOM::Database::Model::UserConnect->new;
    my $user_providers = $user_connect->get_connects_by_user_id($user->{id});

    #user is marked with has_social_signup so he must have info otherwise something worng!.
    die "User social signin info not found" unless $user_providers->[0];

    # Social user with a specific email can only sign up/sign in via the provider (social account)
    # by which s/he has created an account at the beginning.
    # Getting the first provider from $user_providers is based on the assumption that
    # there is exactly one provider for a social user.
    return {
        error => 'INVALID_PROVIDER',
        args  => [ucfirst($user_providers->[0])]} if ($provider_name ne $user_providers->[0]);

    #all good
    return {success => 1};
}

=head2 _login

Set the required session for signing in the user and redirect the user to authorize

=cut

sub _login {
    my ($c, $user) = @_;
    # login client to the system
    $c->session(_sls_user_id => $user->{id});
    stats_inc('login.social_login.success', {tags => [$c->_dd_brand_tag]});
    return $c->redirect_to_auth_page;
}

=head2 _dd_brand_tag

Helper function to get the datadog brand tag name

=cut

sub _dd_brand_tag {
    my $c     = shift;
    my $brand = $c->stash('query_params')->{brand};
    return "brand:$brand";
}

=head2 _process_new_user

Creates a new virtual account for the user. and map his signup data in user connect.
Also send signup track event.

=cut

sub _process_new_user {
    my ($c, $user_data, $utm_data) = @_;
    my $account = BOM::OAuth::Common::create_virtual_account($user_data, $utm_data);
    if ($account->{error}) {
        return {
            error => 'INVALID_RESIDENCE',
            args  => [code2country($user_data->{residence})]}
            if ($account->{error}->{code} eq 'invalid residence');
        return {error => $account->{error}};
    }

    #To integrate with oneall, we need to have $provider_data object with uid
    #So we'll rely on 'sls_email' as uid for social login.
    my $provider_data = {
        user => {
            identity => {
                provider              => $user_data->{provider},
                provider_identity_uid => "sls_$user_data->{email}"
            }}};
    my $user_connect = BOM::Database::Model::UserConnect->new;
    # connect sls provider data to user identity
    $user_connect->insert_connect($account->{user}->{id}, $user_data->{email}, $provider_data);

    # track social signup on Segment
    $c->_track_new_user($account);

    # initialize user_id and link account to social login.
    stats_inc('login.social_login.new_user_created', {tags => [$c->_dd_brand_tag, "provider:$user_data->{provider}"]});

    return $account;
}

=head2 _track_new_user

Emit signup event.

=cut

sub _track_new_user {
    my ($c, $account) = @_;

    my $utm_tags = {};
    foreach my $tag (qw( utm_source utm_medium utm_campaign gclid_url date_first_contact signup_device utm_content utm_term)) {
        $utm_tags->{$tag} = $c->session($tag) if $c->session($tag);
    }

    BOM::Platform::Event::Emitter::emit(
        'signup',
        {
            loginid    => $account->{client}->loginid,
            properties => {
                type       => 'trading',
                subtype    => 'virtual',
                user_agent => $c->req->headers->user_agent // '',
                utm_tags   => $utm_tags,
            }});
}

sub callback {
    my $c                 = shift;
    my $provider_response = $c->_extract_request_parametrs;
    $c->stash('query_params' => delete $provider_response->{query_params});
    my $user_data;

    try {
        $user_data = $c->_retrieve_user_info($provider_response);    #first thing to do to invalidate auth_code.
    } catch ($e) {
        my $additional_info = "Error while retrive user info from $provider_response->{provider}";
        $log->errorf($c->_to_error_message($e, $additional_info));
    }

    try {
        #invalid brand, will never be hit per current implementation.
        return $c->redirect_to_auth_page('INVALID_BRAND')
            unless $c->stash('query_params')->{brand};
        ## Somthing worng with the service?
        unless (ref $user_data) {
            return $c->redirect_to_auth_page('NO_USER_IDENTITY');
        }
        ## Bad request, could be due to missing/manipulated data..
        if ($user_data->{error}) {
            $log->errorf($c->_to_error_message("Exchange failed with $provider_response->{provider}: $user_data->{error}"));
            return $c->redirect_to_auth_page('NO_AUTHENTICATION');
        }

        my $email = $user_data->{email};

        # Check that whether user has granted access to a valid email address in her/his social account
        return $c->redirect_to_auth_page('INVALID_SOCIAL_EMAIL', (ucfirst $user_data->{provider}))
            if !$email || !Email::Valid->address($email);

        my $user = eval { BOM::User->new(email => $email) };

        ##sign up
        unless ($user) {
            my $utm_data      = $c->_extract_utm_details;
            my $new_user_data = {$user_data->%*, $c->_extract_user_details->%*};
            my $account       = $c->_process_new_user($new_user_data, $utm_data);

            return $c->redirect_to_auth_page($account->{error}, $account->{args}->@*) if $account->{error};

            $user = $account->{user};
            # User has used social login to signup
            # don't notify about unkown login
            $c->session(_is_social_signup => 1);
            return $c->_login($user);
        }

        ##signin
        my $res = _is_valid_signin_attempt($user, $user_data->{provider});
        if ($res->{success}) {

            #Remove social signup session if it exists and user is logging in
            delete $c->session->{_is_social_signup};

            return $c->_login($user);
        }

        #faild signin attempt;
        return $c->redirect_to_auth_page($res->{error}, ($res->{args} // [])->@*);
    } catch ($e) {
        $log->errorf($c->_to_error_message($e));
        stats_inc('login.social_login.error', {tags => [$c->_dd_brand_tag]});
        return $c->redirect_to_auth_page('invalid');
    }
}

=head2 app_callback

Handle app_id callback (mobile flow).

=cut

sub app_callback {
    my $c                 = shift;
    my $provider_response = $c->req->params->to_hash;
    my $app_id            = $c->stash('app_id');

    return $c->_bad_request('the request was missing app_id') unless $app_id;
    my $oauth_model = BOM::Database::Model::OAuth->new;
    my $app         = $oauth_model->verify_app($app_id);
    return $c->_bad_request('the request was missing valid app_id') unless $app;

    my @params = ($provider_response->%*);
    return BOM::OAuth::Common::redirect_to($c, $app->{redirect_uri}, \@params);

}

=head2 _retrieve_user_info

retrieve user information from exchange social login call

=cut

sub _retrieve_user_info {
    my ($c, $provider_response) = @_;
    my $exchange_params = $c->_extract_exchange_params($provider_response);
    my $config          = BOM::Config::service_social_login();
    my $service         = BOM::OAuth::SocialLoginClient->new(
        host => $config->{social_login}->{host},
        port => $config->{social_login}->{port});
    #wrapping the url because $c->req->url->host is undef!
    my $current_domain = Mojo::URL->new($c->req->url->to_abs)->host;

    my $user_response = $service->retrieve_user_info(social_login_callback_base($current_domain), $exchange_params);
    return $user_response;
}

=head2 _extract_exchange_params

prepare param for exchange request to fetch user info

=cut

sub _extract_exchange_params {
    my ($c, $provider_response) = @_;
    my $exchange_params = {
        cookie_params => {
            state         => $provider_response->{provider_params}->{state}         // '',
            nonce         => $provider_response->{provider_params}->{nonce}         // '',
            code_verifier => $provider_response->{provider_params}->{code_verifier} // ''
        },
        uri_params => {
            uri_state => $provider_response->{callback_params}->{state} // '',
            auth_code => $provider_response->{callback_params}->{code}  // ''
        },
        provider_name => $provider_response->{provider} // ''
    };
    return $exchange_params;
}

=head2 _use_oneall_mobile

determine which service will be used by mobile app, social-login or oneAll based on feature flag;

=cut

sub _use_oneall_mobile {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->check_for_update;
    return $app_config->social_login->use_oneall_mobile;
}

=head2 get_providers

fetch providers from  social login service

=cut

sub get_providers {
    my $c         = shift;
    my $providers = [];
    # No need to make the request if we are using oneall.
    if (_use_oneall_mobile) {
        return $c->render(
            json   => {data => $providers},
            status => 200,
        );
    }

    try {
        my $config  = BOM::Config::service_social_login();
        my $service = BOM::OAuth::SocialLoginClient->new(
            host => $config->{social_login}->{host},
            port => $config->{social_login}->{port});

        my $current_domain = Mojo::URL->new($c->req->url->to_abs)->host;
        my $providers      = $service->get_providers(social_login_callback_base($current_domain), $c->stash('app_id'));
        if (scalar @$providers) {
            return $c->render(
                json   => {data => $providers},
                status => 200,
            );
        }
    } catch ($e) {
        $log->errorf($c->_to_error_message($e, "[REST]"));
    }

    # Return internal server error
    return $c->render(
        json => {
            error_code => 'SERVER_ERROR',
            message    => 'An error occurred while processing the get_providers request'
        },
        status => 500,
    );
}

=head2 _to_error_message

Returns a string represents social login exception with possiblity to provide additional info.
Will append the request details. 

=cut

sub _to_error_message {
    my $c         = shift;
    my $exception = shift;
    my $message   = shift;

    my $exception_message = exception_string($exception);
    my $request_details   = request_details_string($c->req, $c->stash('request'));
    my $result            = "Social Login exception - ";
    if ($message) {
        $result .= "$message - ";
    }
    $result .= "$exception_message while processing $request_details";
    return $result;
}

1;
