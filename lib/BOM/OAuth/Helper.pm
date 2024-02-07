package BOM::OAuth::Helper;

use strict;
use warnings;
use MIME::Base64 qw(encode_base64 decode_base64);
use JSON::MaybeXS;    #Using `JSON::MaybeXS` to maintain order of the result string.

use Exporter qw(import);
our @EXPORT_OK = qw(request_details_string exception_string social_login_callback_base strip_array_values);

=head2 extract_brand_from_params

Return undef or brand name if exists.

=cut

sub extract_brand_from_params {
    my ($self, $params) = @_;

    # extract encoded brand name from parameters curried from oneall
    my $brand_key = (grep { /(?:amp;){0,1}brand/ } keys %$params)[0];

    return undef unless $brand_key;    ## no critic (ProhibitExplicitReturnUndef)

    my $brand = $params->{$brand_key};

    return undef unless $brand;        ## no critic (ProhibitExplicitReturnUndef)

    if (ref($brand) eq 'ARRAY') {
        return undef unless $brand->[0] =~ /\w+/;    ## no critic (ProhibitExplicitReturnUndef)

        return $brand->[0];
    }

    return $brand;
}

=head2 setup_social_login

Get the providers info form social login service
inject the required sls cookie, and stash the links so they can be used by the template.

=cut

sub setup_social_login {
    my $c = shift;

    return if $c->_use_oneall_web;    #no need to make the request if we are using oneall.

    my $config  = BOM::Config::service_social_login();
    my $service = BOM::OAuth::SocialLoginClient->new(
        host => $config->{social_login}->{host},
        port => $config->{social_login}->{port});

    #wrapping the url because $c->req->url->host is undef!
    my $current_domain = Mojo::URL->new($c->req->url->to_abs)->host;

    my $providers = $service->get_providers(social_login_callback_base($current_domain));
    die $providers unless ref $providers;

    my $links;
    my $session = {};
    for my $provider ($providers->@*) {
        my $url           = delete $provider->{auth_url};
        my $provider_name = delete $provider->{name};
        $links->{$provider_name}   = $url;
        $session->{$provider_name} = $provider;
    }

    $session->{"query_params"} = strip_array_values($c->req->params->to_hash);

    set_social_login_cookie($c, $session);
    $c->stash('social_login_links' => $links);

    return $links;
}

=head2 set_social_login_cookie

adds a signed, secure, http-only and CORS, cookie to the response named 'sls' contains the passed social login info.

=cut

sub set_social_login_cookie {
    my ($c, $session) = @_;

    my $encoded = encode_base64(JSON::MaybeXS->new->utf8->canonical->encode($session), '');
    $c->signed_cookie(
        'sls' => $encoded,
        {
            secure   => 1,
            httponly => 1,
            samesite => 'None'
        });    # samesite None required for apple to be able to get the cookie from CORS POST request.
}

=head2 get_social_login_cookie

retrieve social login cookie, named 'sls'

=cut

sub get_social_login_cookie {
    my $c      = shift;
    my $cookie = $c->signed_cookie('sls');
    die '"sls" Cookie is missing' unless $cookie;
    return JSON::MaybeXS->new->utf8->decode(decode_base64($cookie));
}

=head2 request_details_string

Returns a formatted string of the request path and details about request's
IP, Country, Referrer, and User_Agent.

=cut

sub request_details_string {
    my $request         = shift;
    my $request_context = shift;

    my $path = $request->url->path->to_string;

    my $request_headers = $request->headers;

    my $request_details = JSON::MaybeXS->new->utf8->canonical->encode({
        IP         => $request_context->client_ip,
        Country    => $request_context->country_code,
        Referrer   => $request_headers->referrer,
        User_Agent => $request_headers->user_agent,
    });

    my $full_message = "request to $path $request_details";
    return $full_message;
}

=head2 exception_string

Unify different forms of exceptions raised from bom-oauth into a string.

=cut

sub exception_string {
    my $exception = shift;

    if (defined $exception && !ref $exception) {
        return $exception;
    }

    if (ref $exception eq 'Mojo::Exception') {
        return $exception->{message};
    }

    if (ref $exception eq 'ARRAY') {
        my $message = "";
        $message .= $_ for $exception->@*;
        return $message;
    }

    if (ref $exception eq 'HASH' && $exception->{code}) {
        my $message = $exception->{code};
        $message .= ": $exception->{message}" if $exception->{message};
        return $message;
    }

    return "Unknown Error";
}

=head2 social_login_callback_base

generates the social login callback base url for the given domain.

=over 4

=item * C<domain> a string of the domain the request is coming from.

=back

=cut

sub social_login_callback_base {
    my $domain = shift;
    return "https://$domain/oauth2/social-login/callback";
}

=head2 strip_array_values

strip out the values in a hash that are arrays and return a hash with the same keys and the last value of the array.
If the array is empty, the value will be an empty string.
If the value is not an array, it will be returned as is.

=over 4

=item * C<hash> a hashref that we need to strip its values.

=back 

=cut

sub strip_array_values {
    my $hash = shift;

    if (ref $hash ne 'HASH') {
        return $hash;
    }

    my $res = {};
    foreach my $key (keys $hash->%*) {
        if (ref $hash->{$key} eq 'ARRAY') {
            $res->{$key} = scalar $hash->{$key}->@* ? $hash->{$key}->[-1] : '';
            next;
        }
        $res->{$key} = $hash->{$key};
    }
    return $res;
}

1;
