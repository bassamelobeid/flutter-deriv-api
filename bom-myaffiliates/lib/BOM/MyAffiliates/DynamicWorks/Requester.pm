package BOM::MyAffiliates::DynamicWorks::Requester;

use Object::Pad;

=head1 NAME

Requester - A Perl class for interacting with the Dynamic Works API to create new users using HTTP::Tiny.

=head1 SYNOPSIS

Abstract class that has to be inherited by the child classes to interact with the Dynamic Works API

    package BOM::MyAffiliates::DynamicWorks::SyntellicoreRequester;

    use Object::Pad;

    class BOM::MyAffiliates::DynamicWorks::SyntellicoreRequester :isa(BOM::MyAffiliates::DynamicWorks::Requester) {

        method getConfig {
            my $config = BOM::Config::third_party()->{dynamic_works}->{syntellicore};

            die "Config not defined for syntellicore_crm" unless $config;

            return $config;
        }

    }


=head1 DESCRIPTION

This module provides a modern and simple interface for interacting with the Syntellicore API

=cut

=head1 AUTO-GENERATED METHODS

This class uses C<Object::Pad> which auto-generates the following methods:

The following fields have corresponding reader methods:

=head2 user_login

    my $value = $object->user_login;

=head2 user_password

    my $value = $object->user_password;

=cut

use strict;
use warnings;
use HTTP::Tiny;
use JSON::MaybeUTF8 qw(:v1);
use Time::HiRes     qw(sleep);
use Cache::RedisDB;

use BOM::Config;

class BOM::MyAffiliates::DynamicWorks::Requester {
    field $endpoint;
    field $api_key;
    field $version;
    field $user_login :reader;    #=> will create a method "user_login"
    field $user_password :reader;    #=> will create a method "user_password"
    field $max_attempts = 3;
    field $backoff_factor = 2;
    field $http;

=head1 METHODS

=head2 new

Defines the attributes of the class

=cut

    BUILD {
        $http = HTTP::Tiny->new(verify_SSL => 0);
        my $config = $self->getConfig;
        $endpoint      = $config->{endpoint};
        $api_key       = $config->{api_key};
        $user_login    = $config->{user_login};
        $user_password = $config->{user_password};
        $version       = $config->{version} || '1';

    }

=head2 api_request

Performs a request to dynamic work api

=over 4

=item * Arguments

The method expects a hash reference containing the following

=over 4

=item * C<api> - the api method to call

=item * C<method> - GET, POST or PUT

=item * C<path> - url path relative to /api/ without trailing slashes

=item * C<content> - payload for POST/PUT requests

=item * C<do_not_authenticate> - if true, the request will not be authenticated

=back

=item * Returns

The method returns a hash reference containing the response from the API

=back

=cut

    method api_request ($args) {

        my $content             = $args->{content};
        my $api                 = $args->{api};
        my $method              = $args->{method};
        my $do_not_authenticate = $args->{do_not_authenticate};
        my $url                 = "$endpoint/gateway/api/$version/syntellicore.cfc?method=$api";

        my $access_token = undef;

        for (my $attempt = 1; $attempt <= $max_attempts; $attempt++) {

            unless ($do_not_authenticate) {
                $access_token = $self->getAccessToken();
                $content->{access_token} = $access_token if defined $access_token;
            }

            my $params = $http->www_form_urlencode($content);

            my $response = $http->request(
                $method,
                $url . '&' . $params,
                {
                    headers => {
                        'Content-Type' => "application/json",
                        'api_key'      => $api_key,
                    }

                });

            my $content = decode_json_text($response->{content});
            if ($content->{info}->{code} eq '401') {
                $access_token = $self->refreshToken();
            } elsif ($response->{success}) {
                return $content;
            }

            my $sleep_time = $backoff_factor**($attempt - 1);
            sleep($sleep_time);

        }
        # return a valid error object instead of undef
        return undef;

    }

=head2 refreshToken

Refreshes the access token from the API and stores it in the cache

=over 4

=item * Returns

The method returns the new access token

=back

=cut

    method refreshToken {
        my $response = $self->userLogin();

        my $token;
        $token = $response->{data}[0]->{authentication_token} if defined $response;

        if (!defined $token) {
            return undef;
        }
        Cache::RedisDB->set('dw_api', 'token', $token, 3600);
        return $token;
    }

=head2 getAccessToken

Retrieves the access token from the cache and refreshes it if it is not available

=over 4

=item * Returns

The method returns the access token

=back

=cut

    method getAccessToken () {
        my $token = Cache::RedisDB->get('dw_api', 'token');

        if (!defined $token) {
            return $self->refreshToken;
        }

        return $token;
    }

=head2 userLogin

Logs in the user to the API. Has to be implemented in the child class

=over 4

=item * Returns

The method returns a hash reference containing the response from the API

=back

=cut

    method userLogin {
        die "userLogin method is not defined in child class";
    }

=head2 getConfig

Returns the configuration for the API. Has to be implemented in the child class

=over 4

=item * Returns

The method returns a hash reference containing the configuration for the API

=back

=cut

    method getConfig {
        die "getConfig method is not defined in child class";
    }
}

1;
