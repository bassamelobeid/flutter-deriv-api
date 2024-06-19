package BOM::OAuth::CTrader;

use strict;
use warnings;

no indirect;

use feature qw(state);

use Mojo::Base 'Mojolicious::Controller';
use Mojo::Parameters;
use Net::CIDR;

use Log::Any qw($log);

use BOM::User::Client;
use BOM::Database::Model::OAuth;
use BOM::TradingPlatform::CTrader;
use Syntax::Keyword::Try;

use JSON::WebToken  qw(encode_jwt decode_jwt);
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);

use Digest::SHA1 qw(sha1_hex);

# Based on documentation API access token should be valid at least for a week
# https://help.ctrader.com/broker-oauth-inapp/authenticate-ctrader-backend/

use constant {
    JWT_TTL => 60 * 60 * 24 * 7,
    JWT_APP => 'ctrader',
    JWT_SUB => 'auth',
};

=head1 NAME

BOM::OAuth::cTrader

=head1 DESCRIPTION

The package provides controllers  for cTrader OAuth flow.

=cut

=head2 crm_api_token

API controller

Authenticates all subsequent requests made by the cTrader backend area by exchanging a pre-generated valid password into an access token.
This token should be valid for at least a week.

=over 4

=item * C<password> Password for access cTrader OAuth API.

=back

=cut 

sub crm_api_token {
    my $c = shift;

    return $c->reply->not_found unless $c->is_access_allowed;

    my $body = $c->req->json;

    if (ref $body ne 'HASH' || !$c->validate_password($body->{password})) {
        return $c->render(
            json => {
                error_code => 'INVALID_PASSWORD',
                message    => 'The provided password is invalid.'
            },
            status => 401,
        );
    }

    # We use password as part of the secret to be able easily
    # invalidate all JWT tokens with outdated password
    my $token = encode_jwt({
            app => JWT_APP,
            sub => JWT_SUB,
            exp => time + JWT_TTL,
        },
        $c->jwt_secret . sha1_hex($body->{password}));

    $c->render(json => {crmApiToken => $token});
}

=head2 pta_login

API controller

Verifies an onetime token and exchanges it for a long-term access token.

=over 4

=item * C<code> onetime token

=back

=cut 

sub pta_login {
    my ($c) = @_;

    return $c->reply->not_found unless $c->is_access_allowed;

    if (!$c->validate_token($c->param('crmApiToken'))) {
        return $c->render(
            json => {
                error_code => 'INVALID_TOKEN',
                message    => 'The provided token is invalid.'
            },
            status => 403,
        );
    }

    my $body = $c->req->json;

    my $ott_params;
    try {
        $ott_params = BOM::TradingPlatform::CTrader->decode_login_token($body->{code});
    } catch {
        return $c->render(
            json => {
                error_code => 'INVALID_OTT_TOKEN',
                message    => 'The provided token is invalid.'
            },
            status => 400,
        );
    }

    my $token;
    try {
        my $oauth_model = BOM::Database::Model::OAuth->new;
        $token = $oauth_model->generate_ctrader_token({
            user_id        => $ott_params->{user_id},
            ctid           => $ott_params->{ctid},
            ua_fingerprint => $ott_params->{ua_fingerprint},
        });
        die 'Unable to generate access token' unless $token;
    } catch {
        return $c->render(
            json => {
                error_code => 'SERVER_ERROR',
                message    => 'Failed to generate access token. Try again.'
            },
            status => 500,
        );
    }

    return $c->render(
        json => {
            accessToken => $token,
            userId      => $ott_params->{ctid},
        });
}

=head2 authorize

API controller

Verifies a long-term access token during the automatic re-login flow.

=over 4

=item * C<accessToken> long-term access token

=back

=cut 

sub authorize {
    my ($c) = @_;

    return $c->reply->not_found unless $c->is_access_allowed;

    if (!$c->validate_token($c->param('crmApiToken'))) {
        return $c->render(
            json => {
                error_code => 'INVALID_TOKEN',
                message    => 'The provided token is invalid.',
            },
            status => 403,
        );
    }

    try {
        my $oauth_model = BOM::Database::Model::OAuth->new;
        my $body        = $c->req->json;
        my $token       = $body && $body->{accessToken} && $oauth_model->get_details_of_ctrader_token($body->{accessToken});

        if ($token) {
            return $c->render(json => {userId => $token->{ctrader_user_id}});
        }

        return $c->render(
            json => {
                error_code => 'INVALID_ACCESS_TOKEN',
                message    => 'The provided access token is invalid.',
            },
            status => 404,
        );
    } catch ($e) {
        return $c->render(
            json => {
                error_code => 'SERVER_ERROR',
                message    => 'Failed to validate access token. Try again.'
            },
            status => 500,
        );
    }
}

=head2 generate_onetime_token

API controller

Placeholder  for controller which generatates  onetime tokens that cTrader can authorize cTrader users to Deriv Platform.

=cut 

sub generate_onetime_token {
    my ($c) = @_;

    return $c->reply->not_found unless $c->is_access_allowed;

    if (!$c->validate_token($c->param('crmApiToken'))) {
        return $c->render(
            json => {
                error_code => 'INVALID_TOKEN',
                message    => 'The provided token is invalid.',
            },
            status => 403,
        );
    }

    return $c->render(json => {token => 'generictoken'});
}

=head2 validate_password

Validates password for accessing cTrader OAuth API. 
It checks that provided password is presented in the list of valid API passwords.

=over 4

=item * C<pass> password to be validated

=back

=cut 

sub validate_password {
    my ($c, $pass) = @_;

    return 0 unless defined $pass;

    my $hashed_pass = sha1_hex($pass);

    state $passwd = do {
        +{map { $_ => 1 } $c->get_api_passwords};
    };

    return 1 if $passwd->{$hashed_pass};

    return 0;
}

=head2 get_api_passwords

Returns list of supported API passwords

=cut

sub get_api_passwords {
    my ($c) = @_;

    # We provide possibility to set multiple passwords for this API for rotation purposes.
    return $c->app->config->{ctrader_api}{passwords}->@*;
}

=head2 validate_token

Validates JWT token for accesing OAuth cTrader API

=over 4

=item * C<token> JWT token to be validated 

=back

=cut

sub validate_token {
    my ($c, $token) = @_;

    return 0 unless $token;

    # We check with all supported passwords, in case we do rotation of passwords.
    for my $pass ($c->get_api_passwords) {
        try {
            my $payload = decode_jwt($token, $c->jwt_secret . $pass, 1, ['HS256']);

            next if ($payload->{app} // '') ne JWT_APP;
            next if ($payload->{sub} // '') ne JWT_SUB;
            next if ($payload->{exp} // 0) < time;

            return 1;
        } catch {
            next;
        }
    }

    return 0;
}

=head2 is_access_allowed

Predicate which checks that request is allowed.
It checks that cTrader OAuth API is enabled and client IP is included into list.

=cut

sub is_access_allowed {
    my ($c) = @_;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    return 0 if $app_config->system->suspend->ctrader_oauth_api;

    my $ip = $c->stash('request')->client_ip;

    my @white_listed_networks = $app_config->oauth->ctrader_api->white_listed_networks->@*;

    return 1 unless @white_listed_networks;

    return 1 if Net::CIDR::cidrlookup($ip, @white_listed_networks);

    return 0;
}

=head2 jwt_secret

Returns a secret for signing JWT token.

=cut

sub jwt_secret {
    my ($c) = @_;

    return $c->app->secrets->@[0] // 'dummy_secret';
}

1;
