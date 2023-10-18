use Object::Pad;

class BOM::OAuth::SocialLogin::RestHandler;

use strict;
use warnings;

use BOM::OAuth::Common;
use BOM::OAuth::Helper qw(exception_string social_login_callback_base);
use JSON::MaybeUTF8    qw(encode_json_utf8 decode_json_utf8);
use BOM::Platform::Utility;
use Syntax::Keyword::Try;
use DataDog::DogStatsd::Helper qw( stats_inc );

# Redis key to temporary store
use constant TEMP_KEY => 'SOCIAL::LOGIN::TEMP::';
# Timeout for temporary storage (10 minutes)
use constant TEMP_TIMEOUT            => 600;
use constant REGEX_VALIDATION_KEYS   => {qr{^utm_.+} => qr{^[\w\s\.\-_]{1,100}$}};
use constant OAUTH_BLOCKED_USERS_KEY => 'oauth::blocked_by_user::';

field $redis;
field $sls_service;
field $user_connect_db;

=head2 new 

Constructor.

=cut 

BUILD {
    my %args = @_;
    $redis           = $args{redis};
    $sls_service     = $args{sls_service};
    $user_connect_db = $args{user_connect_db};
}

=head2 _extract_valid_params

Remove utm not valid tags.

=cut 

method _extract_valid_params ($payload) {
    return BOM::Platform::Utility::extract_valid_params([keys $payload->%*], $payload, REGEX_VALIDATION_KEYS);
}

=head2 _validate_social_login_status

Check wether the social login is active or suspended in system. 

=cut 

method _validate_social_login_status ($brand_name) {

    if (BOM::OAuth::Common::is_social_login_suspended()) {
        my $error_code = 'TEMP_DISABLED';
        stats_inc('login.authorizer.validation_failure', {tags => ["brand:$brand_name", "error:$error_code"]});
        die +{
            code   => $error_code,
            status => 500
        };
    }
}

=head2 perform_social_login

Tries to validate user's login request via provided third-party identifiers and token.

Returns an array of associated clients

=cut

method perform_social_login ($payload, $app, $brand_name, $residence) {
    if (!$payload->{code}) {
        die +{
            code   => "MISSED_CONNECTION_TOKEN",
            status => 400,
        };
    }
    my $user_data;
    try {
        $user_data = $self->_retrieve_user_info($app, $payload);
    } catch ($e) {
        stats_inc('login.social_login.connection_failure', {tags => ["brand:$brand_name"]});
        die +{
            code            => "NO_USER_IDENTITY",
            status          => 500,
            additional_info => "Error while retrieve user info from $payload->{provider}:" . exception_string($e)};
    }
    if ($user_data->{error}) {
        die +{
            code            => 'NO_AUTHENTICATION',
            additional_info => "Exchange failed with $payload->{provider}: $user_data->{error}"
        };
    }

    $self->_validate_social_login_status($brand_name);

    my $email = $user_data->{email};
    if (!($email && Email::Valid->address($email))) {
        die +{
            code   => "INVALID_SOCIAL_EMAIL",
            status => 400
        };
    }

    my $user = eval { BOM::User->new(email => $email) };
    my $social_type;

    if ($user) {
        $social_type = 'login';
        $self->_validate_sign_in_attempt($user, $payload->{provider});
    } else {
        $social_type = 'signup';
        $user        = $self->_create_new_user($app->{id}, $payload, $email, $residence, $brand_name);
    }

    stats_inc('login.social_login.success', {tags => ["brand:$brand_name"]});

    return {
        user_id     => $user->{id},
        social_type => $social_type
    };
}

=head2 _create_new_user

Creates a new user in the system, emit required events. 

=cut

method _create_new_user ($app_id, $payload, $email, $residence, $brand_name) {
    my $valid_payload = $self->_extract_valid_params($payload);
    my $user_details  = {
        email              => $email,
        brand              => $brand_name,
        residence          => $residence,
        date_first_contact => $valid_payload->{date_first_contact},
        signup_device      => $valid_payload->{signup_device},
        myaffiliates_token => $valid_payload->{myaffiliates_token},
        gclid_url          => $valid_payload->{gclid_url},
        utm_medium         => $valid_payload->{utm_medium},
        utm_source         => $valid_payload->{utm_source},
        utm_campaign       => $valid_payload->{utm_campaign},
        source             => $app_id,
    };
    my $utm_details = $self->_extract_utm_details($valid_payload);
    my $account     = $self->_process_new_user($user_details, $utm_details, $valid_payload->{provider});

    $self->_track_new_user($account, $valid_payload);

    stats_inc('login.social_login.new_user_created', {tags => ["brand:$brand_name", "provider:$valid_payload->{provider}"]});
    return $account->{user};
}

=head2 _extract_utm_details

get an object of utm tags from payload.

=cut 

method _extract_utm_details ($payload) {
    return {
        utm_ad_id        => $payload->{utm_ad_id},
        utm_adgroup_id   => $payload->{utm_adgroup_id},
        utm_adrollclk_id => $payload->{utm_adrollclk_id},
        utm_campaign_id  => $payload->{utm_campaign_id},
        utm_content      => $payload->{utm_content},
        utm_fbcl_id      => $payload->{utm_fbcl_id},
        utm_gl_client_id => $payload->{utm_gl_client_id},
        utm_msclk_id     => $payload->{utm_msclk_id},
        utm_term         => $payload->{utm_term},
    };
}

=head2 _track_new_user

gather the required utm tags from payload and emit signup event.

=cut 

method _track_new_user ($account, $payload) {
    # track social signup on Segment
    my $utm_tags  = {};
    my @tags_list = qw(utm_source utm_medium utm_campaign gclid_url date_first_contact signup_device utm_content utm_term);

    foreach my $tag (@tags_list) {
        $utm_tags->{$tag} = $payload->{$tag} if $payload->{$tag};
    }

    BOM::Platform::Event::Emitter::emit(
        'signup',
        {
            loginid    => $account->{client}->loginid,
            properties => {
                type     => 'trading',
                subtype  => 'virtual',
                utm_tags => $utm_tags
            }});
}

=head2 _validate_sign_in_attempt

For existing users do the checks to ensure the login is valid, three mainly: user is social, same provider, and not blocked.

=cut

method _validate_sign_in_attempt ($user, $provider_name) {

    if (!$user->{has_social_signup}) {
        die +{
            code => "NO_LOGIN_SIGNUP",
        };
    }
    my $user_providers = $user_connect_db->get_connects_by_user_id($user->{id});
    if (defined $user_providers->[0] and $provider_name ne $user_providers->[0]) {
        die +{code => "INVALID_PROVIDER"};
    }

    if ($redis->get(OAUTH_BLOCKED_USERS_KEY . $user->id)) {
        stats_inc('login.authorizer.block.hit');

        die +{
            code   => "SUSPICIOUS_BLOCKED",
            status => 429,
        };
    }
}

=head2 _process_new_user

Create a new user in the system and register as a social user.

=cut

method _process_new_user ($user_data, $utm_data, $provider_name) {
    my $account = BOM::OAuth::Common::create_virtual_account($user_data, $utm_data);

    if ($account->{error}) {
        if ($account->{error}->{code} eq 'invalid residence') {
            die +{
                code   => "INVALID_RESIDENCE",
                status => 400
            };
        }
        if ($account->{error}->{code} eq 'duplicate email') {
            die +{
                code   => "DUPLICATE_EMAIL",
                status => 400
            };
        }
        die +{code => $account->{error}->{code}};
    }
    my $user = $account->{user};

    #To integrate with oneall, we need to have $provider_data object with uid
    my $provider_data = BOM::OAuth::Common::get_oneall_like_provider_data($user_data->{email}, $provider_name);

    # connect social login  provider data to user identity
    $user_connect_db->insert_connect($user->{id}, $user->{email}, $provider_data);
    return $account;
}

=head2 _to_exchange_params

Translate the payload object to exchange object accepted by Social Login service.

=cut

method _to_exchange_params ($payload) {
    return {
        cookie_params => {
            state         => $payload->{state},
            nonce         => $payload->{nonce},
            code_verifier => $payload->{code_verifier},
        },
        uri_params => {
            uri_state => $payload->{callback_state},
            auth_code => $payload->{code}
        },
        provider_name => $payload->{provider}};
}

=head2 _retrieve_user_info

Call Social Login Service and to exchange the code and get the user's info. 

=cut 

method _retrieve_user_info ($app, $payload) {
    my $exchange_params = $self->_to_exchange_params($payload);
    $exchange_params->{app_id} = $app->{id};

    return $sls_service->retrieve_user_info($payload->{domain}, $exchange_params);
}

=head2 get_cached_login_attempt

Check Redis for an existing login attempt, and fetch it if exists.

=cut 

method get_cached_login_attempt ($state) {
    if (!$state) {
        return undef;
    }
    try {
        my $cached = $redis->get(TEMP_KEY . $state);
        return decode_json_utf8($cached) if $cached;
    } catch {
        return undef;
    }
}

=head2 cache_login_attempt

Cache the login attempt in redis.

=cut 

method cache_login_attempt ($state, $user_data) {
    try {
        return $redis->setex(TEMP_KEY . $state, TEMP_TIMEOUT, encode_json_utf8($user_data));
    } catch {
        return 0;
    }
}

=head2 clear_cache

remove the login attempt identifed by $state from redis.

=cut 

method clear_cache ($state) {
    try {
        return $redis->del(TEMP_KEY . $state);
    } catch {
        return 0;
    }
}

1;
