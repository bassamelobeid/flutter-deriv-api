package BOM::OAuth::RestAPI;

use strict;
use warnings;
no indirect;

=head1 NAME

BOM::OAuth::RestAPI - JSON Rest API for application and user authentication

=head1 DESCRIPTION

Implementation based on the following spec: https://wikijs.deriv.cloud/en/Backend/architecture/proposal/bom_oauth_rest_api

=cut

use DataDog::DogStatsd::Helper qw( stats_inc );
use Digest::SHA qw( hmac_sha256_hex );
use Digest::MD5 qw( md5_hex );
use Email::Valid;
use Format::Util::Strings qw( defang );
use JSON::MaybeXS;
use JSON::WebToken;
use List::Util qw( none );
use Log::Any qw( $log );
use Mojo::Base 'Mojolicious::Controller';
use Syntax::Keyword::Try;
use Text::Trim;
use WWW::OneAll;

use BOM::User::TOTP;
use BOM::Config::Redis;
use BOM::Config;
use BOM::Database::Model::UserConnect;
use BOM::OAuth::Common;
use BOM::OAuth::Static qw( get_api_errors_mapping get_valid_login_types );
use BOM::Platform::Token::API;

use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);

# Challenge takes 10 minutes (600 seconds amirite) to expire.
use constant CHALLENGE_TIMEOUT => 600;

# JWT takes 10 minutes (600 seconds amirite) to expire.
use constant JWT_TIMEOUT => 600;

# Attempts to generate new token to ensure uniquness.
use constant TOKEN_GENERATION_ATTEMPTS => 3;

# Length of allowed url params keys
use constant URL_PARAMS_LENGTH => 15;

# Redis key to temporary store OneAll response
use constant ONE_ALL_TEMP_KEY => 'ONE::ALL::TEMP::';

# Timeout for temporary OneAll storage (10 minutes)
use constant ONE_ALL_TEMP_TIMEOUT => 600;

use constant {
    ONE_TIME_TOKEN_TIMEOUT => 60,                         # one time token takes 1 minute (60 seconds) to expire.
    ONE_TIME_TOKEN_LENGTH  => 20,
    ONE_TIME_TOKEN_KEY     => 'oauth::one_time_token::'
};

use constant {
    REFRESH_TOKEN_LENGTH  => 29,
    REFRESH_TOKEN_TIMEOUT => 60 * 60 * 24 * 60            # 60 days.
};

use constant {
    LOGIN_URI              => '/oauth2/authorize',        # redirect to this uri if an error occur in one_time_token endpoint.
    DEFAULT_APP_ID         => 16929,                      # default redirect to deriv login page.
    DEFAULD_APP_BRAND_NAME => 'deriv'
};

=head2 verify

This endpoint generates a challenge for the application's authentication attempt

It takes the following JSON payload:

=over 4

=item * C<app_id> the numeric application id being authenticated

=back

It renders a JSON with the following structure:

=over 4

=item * C<challange> a challenge string for this authentication attempt

=item * C<expire> an expiration timestamp for this authentication attempt

=back

=cut

sub verify {
    my $c = shift;

    return $c->_make_error('NEED_JSON_BODY', 400) unless $c->req->json;

    my $app_id = defang($c->req->json->{app_id}) or return $c->_make_error('INVALID_APP_ID', 400);

    my $oauth_model = BOM::Database::Model::OAuth->new;
    return $c->_make_error('UNOFFICIAL_APP', 400) unless $oauth_model->is_official_app($app_id);

    my $expire = time + CHALLENGE_TIMEOUT;
    my $model  = BOM::Database::Model::OAuth->new();

    return $c->_unauthorized unless $model->is_official_app($app_id);

    $c->render(
        json => {
            challenge => $c->_challenge($app_id, $expire),
            expire    => $expire,
        },
        status => 200
    );
}

=head2 authorize

This endpoint authorizes those requests that send a valid solution for the challenge.

It takes a JSON payload as:

=over 4

=item * C<solution> the string that solves the challenge

=item * C<app_id> the application id being authenticated

=item * C<expire> the expiration timestamp of the authentication attempt

=back

It renders a JSON with the following structure:

=over 4

=item * C<token> a JWT that authorizes the application

=back

=cut

sub authorize {
    my $c = shift;

    return $c->_make_error('NEED_JSON_BODY', 400) unless $c->req->json;

    my $app_id = defang($c->req->json->{app_id}) or return $c->_make_error('INVALID_APP_ID',           400);
    my $expire = defang($c->req->json->{expire}) or return $c->_make_error('INVALID_EXPIRE_TIMESTAMP', 400);

    return $c->_make_error('INVALID_EXPIRE_TIMESTAMP', 400) if time > $expire;

    my $oauth_model = BOM::Database::Model::OAuth->new;
    return $c->_make_error('UNOFFICIAL_APP', 400) unless $oauth_model->is_official_app($app_id);
    return $c->_make_error('INVALID_APP_ID', 400) unless $oauth_model->verify_app($app_id);

    my $solution  = defang($c->req->json->{solution});
    my $tokens    = $oauth_model->get_app_tokens($app_id);
    my $challenge = $c->_challenge($app_id, $expire);

    return $c->_make_error('NO_APP_TOKEN_FOUND', 404) unless $tokens;

    for my $token ($tokens->@*) {
        my $expected = hmac_sha256_hex($challenge, $token);

        if ($expected eq $solution) {
            return $c->render(
                json   => {token => $c->_jwt_token($app_id)},
                status => 200,
            );
        }
    }

    return $c->_make_error;
}

=head2 login

This endpoint perfoms login action via provided credentials

=over 4

=item * C<app_id> - Required. the app id for request context determination

=item * C<type> - the type of login (B<system> or B<social>)

=item * C<email> - the user email. required for B<system> login

=item * C<password> - the account password. required for B<system> login

=item * C<connection_token> - the OneAll connection token. required for B<social> login

=back

Returns an array of loginids along with the access token as a json

=cut

sub login {
    my $c = shift;

    return $c->_make_error('NEED_JSON_BODY', 400) unless $c->req->json;

    my $token = defang $c->req->headers->header('Authorization');
    my ($jwt) = $token =~ /^Bearer\s(.*)/s;

    return $c->_make_error('INVALID_TOKEN') unless $jwt && (my $payload = $c->_validate_jwt($jwt));

    my $encoded_app_id = $payload->{app};

    my $app_id = defang $c->req->json->{app_id};
    return $c->_make_error('INVALID_APP_ID', 400) if !$app_id || $app_id !~ /^[0-9]+$/ || $encoded_app_id ne $app_id;

    my $oauth_model = BOM::Database::Model::OAuth->new;
    return $c->_make_error('UNOFFICIAL_APP', 400) unless $oauth_model->is_official_app($app_id);

    my $app = $oauth_model->verify_app($app_id);
    return $c->_make_error('INVALID_APP_ID', 400) unless $app;

    my $login_type = defang $c->req->json->{type};
    return $c->_make_error('INVALID_LOGIN_TYPE', 400) if !$login_type || none { $_ eq $login_type } get_valid_login_types;

    my $r          = $c->stash('request');
    my $brand_name = $c->stash('brand')->name;
    return $c->_make_error('INVALID_BRAND', 400) unless $brand_name;

    my $date_first_contact = $c->req->json->{date_first_contact} // undef;
    return $c->_make_error('INVALID_DATE_FIRST_CONTACT', 400) if $date_first_contact && $date_first_contact !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;

    # Check is current IP blocked.
    my $redis = BOM::Config::Redis::redis_auth;
    my $ip    = $r->client_ip // '';
    if ($ip && $redis->get("oauth::blocked_by_ip::$ip")) {
        stats_inc('login.authorizer.block.hit');
        return $c->_make_error('SUSPICIOUS_BLOCKED', 429);
    }

    my $login;
    try {
        my $method = sprintf '_perform_%s_login', $login_type;

        $login = $c->$method($app, $brand_name);
    } catch ($e) {
        return $c->_make_error($e->{code}, $e->{status});
    }

    return $c->_make_error('SELF_CLOSED') if $login->{login_result}->{self_closed};

    # generate refresh token per user
    my $user = $login->{user};
    return $c->_make_error('NO_USER_IDENTITY') unless $user;

    my $refresh_token;
    try {
        for (0 .. TOKEN_GENERATION_ATTEMPTS) {
            die +{
                code   => "TOKEN_GENERATION_FAILD",
                status => 500
            } if $_ == TOKEN_GENERATION_ATTEMPTS;

            $refresh_token = $oauth_model->generate_refresh_token(REFRESH_TOKEN_LENGTH, $user->{id}, REFRESH_TOKEN_TIMEOUT, $app_id);
            last if $refresh_token;
        }
    } catch ($e) {
        $log->errorf("Error: refresh token generation faild: %s", $e);
        return $c->_make_error($e->{code}, $e->{status});
    }

    my $clients = $login->{clients};
    my $client  = $clients->[0];
    return $c->_make_error('NO_USER_IDENTITY') unless $client;

    if ($c->tx and $c->tx->req and $c->tx->req->headers->header('REMOTE_ADDR')) {
        $ip = $c->tx->req->headers->header('REMOTE_ADDR');
    }
    my $ua_fingerprint = md5_hex($app_id . ($ip // '') . ($c->req->headers->header('User-Agent') // ''));

    # create token per all loginids
    my @tokens;
    foreach my $client (@$clients) {
        my ($access_token) = $oauth_model->store_access_token_only($app_id, $client->loginid, $ua_fingerprint);
        push @tokens,
            {
            'loginid' => $client->loginid,
            'token'   => $access_token,
            };
    }

    stats_inc('login.authorizer.success', {tags => ["brand:$brand_name"]});

    return $c->render(
        json => {
            tokens        => \@tokens,
            refresh_token => $refresh_token
        },
        status => 200
    );
}

=head2 pta_login

This endpoint perfoms login action via provided credentials

=over 4

=item * C<refresh_token> - Required. token to verify the user.

=item * C<app_id> - Required. the destination app id where we should redirect the user to.

=item * C<url_params> - Optional. parameters to append to redirect_uri based on the app id provided.

=back

Returns a one time token which will be used to redirect to app_id redirect uri.

=cut

sub pta_login {
    my $c = shift;

    return $c->_make_error('NEED_JSON_BODY', 400) unless $c->req->json;

    my $r          = $c->stash('request');
    my $brand_name = $c->stash('brand')->name;
    return $c->_make_error('INVALID_BRAND', 400) unless $brand_name;

    # Check is current IP blocked.
    my $redis = BOM::Config::Redis::redis_auth;
    my $ip    = $r->client_ip // '';
    if ($ip && $redis->get("oauth::blocked_by_ip::$ip")) {
        stats_inc('login.authorizer.block.hit');
        return $c->_make_error('SUSPICIOUS_BLOCKED', 429);
    }

    my $token = defang $c->req->headers->header('Authorization');
    my ($jwt) = $token =~ /^Bearer\s(.*)/s;

    return $c->_make_error('INVALID_TOKEN', 401) unless $jwt && (my $payload = $c->_validate_jwt($jwt));

    my $oauth_model   = BOM::Database::Model::OAuth->new;
    my $refresh_token = defang $c->req->json->{refresh_token};
    my $record        = $oauth_model->get_user_app_details_by_refresh_token($refresh_token);

    unless ($record) {
        stats_inc('login.authorizer.validation_failure', {tags => ["brand:$brand_name", "error:INVALID_TOKEN"]});
        BOM::OAuth::Common::failed_login_attempt($c);

        return $c->_make_error('INVALID_REFRESH_TOKEN', 401);
    }

    my $source_app = {id => $payload->{app}};
    return $c->_make_error('INVALID_APP_ID', 400) if $source_app->{id} != $record->{app_id};

    $source_app->{scopes} = $oauth_model->get_app_by_id($source_app->{id})->{scopes};

    my $destination_app = {id => defang $c->req->json->{app_id}};
    my $app             = $oauth_model->verify_app($destination_app->{id});
    return $c->_make_error('INVALID_APP_ID', 400) if !$app || !$destination_app->{id} || $destination_app->{id} !~ /^[0-9]+$/;
    return $c->_make_error('UNOFFICIAL_APP', 400) unless $oauth_model->is_official_app($destination_app->{id});

    $destination_app->{scopes} = $oauth_model->get_app_by_id($destination_app->{id})->{scopes};

    my %allowed_scopes = map { $_ => 0 } $source_app->{scopes}->@*;
    foreach ($destination_app->{scopes}->@*) {
        return $c->_make_error('INVALID_SCOPES', 401) unless exists $allowed_scopes{$_};
    }

    return $c->_make_error('INVALID_REDIRECTION', 400) if $source_app->{id} == $destination_app->{id};

    my $url_params = $c->req->json->{url_params};
    if ($url_params) {
        my $number_of_keys = scalar keys($url_params->%*);
        return $c->_make_error('TOO_MANY_PARAMETERS', 400) if $number_of_keys > URL_PARAMS_LENGTH;

        return $c->_make_error('INVALID_URL_PARAMS', 400) if $number_of_keys && join('', $url_params->%*) !~ /^\w+$/;
    }

    my $one_time_token_params = encode_json_utf8({
            app_id        => $destination_app->{id},
            url_params    => $url_params,
            refresh_token => $refresh_token,
            source_app_id => $record->{app_id}});
    my $one_time_token;

    try {
        for (0 .. TOKEN_GENERATION_ATTEMPTS) {
            die +{
                code   => "TOKEN_GENERATION_FAILD",
                status => 500
            } if $_ == TOKEN_GENERATION_ATTEMPTS;

            $one_time_token = BOM::Platform::Token::API->new->generate_token(ONE_TIME_TOKEN_LENGTH);
            last if $redis->set(ONE_TIME_TOKEN_KEY . $one_time_token, $one_time_token_params, 'EX', ONE_TIME_TOKEN_TIMEOUT, 'NX');
        }
    } catch ($e) {
        $log->errorf("Error: one_time_token generation faild: %s", $e);
        return $c->_make_error($e->{code}, $e->{status});
    }

    return $c->render(
        json   => {one_time_token => $one_time_token},
        status => 200
    );
}

=head2 one_time_token 

Verify one time token and redirect to redirect_uri

=cut

sub one_time_token {
    my $c = shift;

    my $r          = $c->stash('request');
    my $brand_name = $c->stash('brand')->name;
    return $c->_make_login_error('INVALID_BRAND') unless $brand_name;

    my $redis = BOM::Config::Redis::redis_auth;
    my $ip    = $r->client_ip // '';
    if ($ip && $redis->get("oauth::blocked_by_ip::$ip")) {
        stats_inc('login.authorizer.block.hit');
        return $c->_make_login_error('SUSPICIOUS_BLOCKED');
    }

    my $token   = $c->param('one_time_token');
    my $payload = $redis->get(ONE_TIME_TOKEN_KEY . $token);
    unless ($payload) {
        stats_inc('login.authorizer.validation_failure', {tags => ["brand:$brand_name", "error:INVALID_TOKEN"]});
        BOM::OAuth::Common::failed_login_attempt($c);

        return $c->_make_login_error('INVALID_TOKEN');
    }

    my $one_time_token_params;
    try {
        $one_time_token_params = decode_json_utf8($payload);
    } catch ($e) {
        return $c->_make_login_error('INVALID_TOKEN');
    }

    my $url_params = $one_time_token_params->{url_params};

    my $oauth_model   = BOM::Database::Model::OAuth->new;
    my $refresh_token = $one_time_token_params->{refresh_token};
    return $c->_make_login_error('INVALID_REFRESH_TOKEN')
        unless $refresh_token && (my $record = $oauth_model->get_user_app_details_by_refresh_token($refresh_token));

    my $source_app_id = $one_time_token_params->{source_app_id};
    return $c->_make_login_error('INVALID_APP_ID') if $source_app_id != $record->{app_id};
    return $c->_make_login_error('UNOFFICIAL_APP') unless $oauth_model->is_official_app($source_app_id);

    my $binary_user_id     = $record->{binary_user_id};
    my $destination_app_id = $one_time_token_params->{app_id};

    return $c->_make_login_error('UNOFFICIAL_APP', $destination_app_id) unless $oauth_model->is_official_app($destination_app_id);

    my $app = $oauth_model->verify_app($destination_app_id);
    return $c->_make_login_error('INVALID_APP_ID', $destination_app_id) unless $app;

    my $redirect_uri = $app->{redirect_uri};
    return $c->_make_login_error('REDIRECT_URI_NOT_FOUND', $destination_app_id) unless $redirect_uri;

    my $login;
    try {
        $login = $c->_perform_refresh_token_login($app, $refresh_token, $binary_user_id, $brand_name);
    } catch ($e) {
        return $c->_make_login_error($e->{code}, $destination_app_id);
    }

    my $clients = $login->{clients};
    my $client  = $clients->[0];
    return $c->_make_login_error('NO_USER_IDENTITY', $destination_app_id) unless $client;

    # create token per all loginids
    my @url_tokens_params;
    push @url_tokens_params, $url_params->%* if defined $url_params;

    my $client_params = {
        clients => $clients,
        ip      => $ip,
        app_id  => $destination_app_id,
    };
    push @url_tokens_params, BOM::OAuth::Common::generate_url_token_params($c, $client_params);

    stats_inc('login.authorizer.success', {tags => ["brand:$brand_name"]});

    try {
        $redis->del(ONE_TIME_TOKEN_KEY . $token);
    } catch ($e) {
        $log->debugf("Error: while deleting one time token", $e);
        return $c->_make_login_error();
    }

    return BOM::OAuth::Common::redirect_to($c, $redirect_uri, \@url_tokens_params);
}

=head2 _perform_system_login

Tries to validate user's login request via provided credentials.

Returns an array of associated clients

=cut

sub _perform_system_login {
    my ($c, $app, $brand_name) = @_;

    my $email = trim lc(defang $c->req->json->{'email'});
    die +{
        code   => "INVALID_EMAIL",
        status => 400
        }
        unless $email
        && Email::Valid->address($email);

    my $password = $c->req->json->{'password'};
    die +{
        code   => "INVALID_PASSWORD",
        status => 400
    } unless $password;

    my $result = BOM::OAuth::Common::validate_login({
        c        => $c,
        app      => $app,
        email    => $email,
        password => $password,
    });

    if (my $err = $result->{error_code}) {
        stats_inc('login.authorizer.validation_failure', {tags => ["brand:$brand_name", "error:$err"]});
        BOM::OAuth::Common::failed_login_attempt($c);

        die +{
            code => $err,
        };
    }
    _verify_otp($result->{user}, defang($c->req->json->{one_time_password}));

    return $result;
}

=head2 _perform_social_login

Tries to validate user's login request via provided third-party identifiers and token.

Returns an array of associated clients

=cut

sub _perform_social_login {
    my ($c, $app, $brand_name) = @_;

    my $connection_token = $c->req->json->{connection_token};
    die +{
        code   => "MISSED_CONNECTION_TOKEN",
        status => 400,
    } unless $connection_token;

    if (BOM::OAuth::Common::is_social_login_suspended()) {
        stats_inc('login.authorizer.validation_failure', {tags => ["brand:$brand_name", "error:TEMP_DISABLED"]});
        die +{
            code   => "TEMP_DISABLED",
            status => 500
        };
    }

    my $redis = BOM::Config::Redis::redis_auth_write;
    my $data;

    try {
        my $cached = $redis->get(ONE_ALL_TEMP_KEY . $connection_token);
        $data = decode_json_utf8($cached) if $cached;
    } catch {
        $data = undef;
    }

    unless ($data) {
        my $oneall = WWW::OneAll->new(
            subdomain   => $brand_name,
            public_key  => BOM::Config::third_party()->{"oneall"}->{$brand_name}->{public_key},
            private_key => BOM::Config::third_party()->{"oneall"}->{$brand_name}->{private_key},
        );

        $data = eval { $oneall->connection($connection_token); };
    }

    if (!$data || $data->{response}->{request}->{status}->{code} != 200) {
        stats_inc('login.oneall.connection_failure',
            {tags => ["brand:$brand_name", "status_code:" . $data->{response}->{request}->{status}->{code}]});
        die +{
            code   => "NO_USER_IDENTITY",
            status => 500
        };
    }

    $redis->setex(ONE_ALL_TEMP_KEY . $connection_token, ONE_ALL_TEMP_TIMEOUT, encode_json_utf8($data));

    my $provider_result = $data->{response}->{result};
    die +{code => "NO_AUTHENTICATION"} if $provider_result->{status}->{code} != 200 || $provider_result->{status}->{flag} eq 'error';

    my $provider_data = $provider_result->{data};
    my $email         = BOM::OAuth::Common::get_email_by_provider($provider_data);
    my $provider_name = $provider_data->{user}->{identity}->{provider} // '';

    die +{
        code   => "INVALID_SOCIAL_EMAIL",
        status => 400
        }
        if !$email
        || !Email::Valid->address($email);

    my $user_connect = BOM::Database::Model::UserConnect->new;
    my $user         = eval { BOM::User->new(email => $email) };
    if ($user) {
        die +{
            code => "NO_LOGIN_SIGNUP",
        } unless $user->{has_social_signup};

        my $user_providers = $user_connect->get_connects_by_user_id($user->{id});
        die +{code => "INVALID_PROVIDER"} if defined $user_providers->[0] and $provider_name ne $user_providers->[0];
    } else {
        my $residence = $c->stash('request')->country_code;

        my $user_details = {
            email              => $email,
            brand              => $brand_name,
            residence          => $residence,
            date_first_contact => $c->req->json->{date_first_contact},
            signup_device      => $c->req->json->{signup_device},
            myaffiliates_token => $c->req->json->{myaffiliates_token},
            gclid_url          => $c->req->json->{gclid_url},
            utm_medium         => $c->req->json->{utm_medium},
            utm_source         => $c->req->json->{utm_source},
            utm_campaign       => $c->req->json->{utm_campaign},
            source             => $app->{id},
        };
        my $regex_validation_keys = {qr{^utm_.+} => qr{^[\w\s\.\-_]{1,100}$}};
        my @tags_list             = keys $user_details->%*;

        $user_details = BOM::Platform::Utility::extract_valid_params(\@tags_list, $user_details, $regex_validation_keys);

        my $utm_data = {
            utm_ad_id        => $c->req->json->{utm_ad_id},
            utm_adgroup_id   => $c->req->json->{utm_adgroup_id},
            utm_adrollclk_id => $c->req->json->{utm_adrollclk_id},
            utm_campaign_id  => $c->req->json->{utm_campaign_id},
            utm_content      => $c->req->json->{utm_content},
            utm_fbcl_id      => $c->req->json->{utm_fbcl_id},
            utm_gl_client_id => $c->req->json->{utm_gl_client_id},
            utm_msclk_id     => $c->req->json->{utm_msclk_id},
            utm_term         => $c->req->json->{utm_term},
        };
        @tags_list = keys $utm_data->%*;

        $utm_data = BOM::Platform::Utility::extract_valid_params(\@tags_list, $utm_data, $regex_validation_keys);

        # Create virtual client if user not found
        my $account = BOM::OAuth::Common::create_virtual_account($user_details, $utm_data);

        if ($account->{error}) {
            die +{
                code   => "INVALID_RESIDENCE",
                status => 400
            } if $account->{error}->{code} eq 'invalid residence';
            die +{
                code   => "DUPLICATE_EMAIL",
                status => 400
            } if $account->{error}->{code} eq 'duplicate email';
            die +{code => $account->{error}->{code}};
        } else {
            $user = $account->{user};
        }

        # connect oneall provider data to user identity
        $user_connect->insert_connect($user->{id}, $provider_data);

        # track social signup on Segment
        my $utm_tags = {};
        @tags_list = qw(utm_source utm_medium utm_campaign gclid_url date_first_contact signup_device utm_content utm_term);

        foreach my $tag (@tags_list) {
            $utm_tags->{$tag} = $c->req->json->{$tag} if $c->req->json->{$tag};
        }

        BOM::Platform::Event::Emitter::emit(
            'signup',
            {
                loginid    => $account->{client}->loginid,
                properties => {
                    type     => 'trading',
                    subtype  => 'virtual',
                    utm_tags => BOM::Platform::Utility::extract_valid_params(\@tags_list, $utm_tags, $regex_validation_keys),
                }});

        # initialize user_id and link account to social login.
        stats_inc('login.oneall.new_user_created', {tags => ["brand:$brand_name", "provider:$provider_name"]});
    }

    stats_inc('login.oneall.success', {tags => ["brand:$brand_name"]});

    my $result = BOM::OAuth::Common::validate_login({
            c              => $c,
            app            => $app,
            oneall_user_id => $user->{id}});

    _verify_otp($result->{user}, defang($c->req->json->{one_time_password}));

    $redis->del(ONE_ALL_TEMP_KEY . $connection_token);

    return $result;
}

=head2 _perform_refresh_token_login

Tries to validate user's login request via provided refresh token.

Returns an array of associated clients

=cut

sub _perform_refresh_token_login {
    my ($c, $app, $refresh_token, $binary_user_id, $brand_name) = @_;

    my $oauth_model  = BOM::Database::Model::OAuth->new;
    my $user_details = $oauth_model->get_user_app_details_by_refresh_token($refresh_token);

    die +{
        code   => "INVALID_REFRESH_TOKEN",
        status => 400
        }
        unless $user_details
        && $binary_user_id == $user_details->{binary_user_id};

    my $result = BOM::OAuth::Common::validate_login({
        c             => $c,
        user_id       => $binary_user_id,
        refresh_token => $refresh_token,
        app           => $app,
    });

    if (my $err = $result->{error_code}) {
        stats_inc('login.authorizer.validation_failure', {tags => ["brand:$brand_name", "error:$err"]});
        BOM::OAuth::Common::failed_login_attempt($c);

        die +{
            code => $err,
        };
    }

    return $result;
}

=head2 _verify_otp

Checks if OTP is enabled and validates the OTP

=over 4

=item * C<$user> User object

=item * C<$otp> One Time Password

=back

=cut

sub _verify_otp {
    my ($user, $otp) = @_;
    if ($user->{is_totp_enabled}) {
        die +{
            code   => 'MISSING_ONE_TIME_PASSWORD',
            status => 400
        } unless $otp;
        die +{
            code   => 'TFA_FAILURE',
            status => 400
        } unless BOM::User::TOTP->verify_totp($user->{secret_key}, $otp);
    }
}

=head2 _jwt_token

Computes a JWT token for the given application.

It takes the following arguments:

=over 4

=item * C<$app_id> the given application id

=back

Returns a valid expirable JWT.

=cut

sub _jwt_token {
    my ($c, $app_id) = @_;

    my $claims = {
        app => $app_id,
        sub => 'auth',
        exp => time + JWT_TIMEOUT,
    };

    return encode_jwt $claims, $c->_secret();
}

=head2 _validate_jwt

Validate incoming header authorization token

=over 4

=item * C<$token> - the jwt token

=back

Returns extracted app_id if valid otherwise undef

=cut

sub _validate_jwt {
    my ($c, $token) = @_;

    my $claims;
    try {
        $claims = decode_jwt $token, $c->_secret(), 1, ['HS256'];
    } catch ($e) {
        $log->debugf("JWT decode failed with error code: %s", $e);
        return undef;
    }

    if ($claims && $claims->{app} && $claims->{exp} && $claims->{sub} eq "auth") {
        return undef if $claims->{exp} < time;

        return $claims;
    }

    return undef;
}

=head2 _challenge

Computes an HMAC challenge.

It takes the following arguments:

=over 4

=item C<$app_id> the numeric application id for this challenge

=item C<$expire> the expiration timestamp for this challenge

=back

Returns a sha256 hex string.

=cut

sub _challenge {
    my ($c, $app_id, $expire) = @_;
    my $payload = join ',', $app_id, $expire;
    return hmac_sha256_hex($payload, $c->_secret());
}

=head2 _make_error

Helper that make and return a generic error response.

=over 4

=item * C<$error_code> - The error code for prepare message for user end.

=item * C<$status_code> - The http status code

=back

Returns a mojo json response

=cut

sub _make_error {
    my ($c, $error_code, $status_code) = @_;

    $error_code //= 'UNKNOWN';

    my $message;
    $message = get_api_errors_mapping()->{$error_code} if $error_code;
    $message //= get_api_errors_mapping()->{UNKNOWN};

    return $c->render(
        json => {
            error_code => $error_code,
            message    => $message,
        },
        status => $status_code // 401,
    );
}

=head2 _secret

Helper that retrieves the current secret for hmac signing.

=cut

sub _secret {
    my $c = shift;

    return $c->app->secrets->@[0] // 'dummy';
}

=head2 _make_login_error

Create an error based on the api error mapping and redirect to login page.

=over 4

=item C<$error_code> error code to get api errors.

=item C<$app_id> redirect to this app id.

=back

=cut

sub _make_login_error {
    my ($c, $error_code, $app_id) = @_;

    my $error_message = get_api_errors_mapping()->{UNKNOWN};
    $error_message = get_api_errors_mapping()->{$error_code} if $error_code;

    $c->session->{error} = $error_message;

    my $redirect_params = [
        'app_id' => $app_id                  // DEFAULT_APP_ID,
        'brand'  => $c->stash('brand')->name // DEFAULD_APP_BRAND_NAME,
    ];

    return BOM::OAuth::Common::redirect_to($c, LOGIN_URI, $redirect_params);
}

1;
