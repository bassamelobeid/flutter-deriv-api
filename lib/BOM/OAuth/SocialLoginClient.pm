use Object::Pad;

class BOM::OAuth::SocialLoginClient;

use strict;
use warnings;
use Syntax::Keyword::Try;
use HTTP::Tiny;
use JSON::MaybeUTF8 qw(:v1);
use constant OK_STATUS_CODE          => 200;
use constant BAD_REQUEST_STATUS_CODE => 400;

has $http;
has $host;
has $port;

BUILD {
    my %args = @_;
    $host = $args{host};
    $port = $args{port};
}

=head2 http

return http object

=cut

method http {
    return $http //= HTTP::Tiny->new();
}

=head2 api_call

take request method, the endpoint, and the payload. 
sends the request to social login serivce, parse the response and return:
1- json object of code and data returned from service.
2- error string in case of exception thrown. 

=cut 

method api_call ($method, $path, $payload = undef) {

    my $full_path = ($port ? "$host:$port" : $host) . "/social-login$path";
    $full_path = "http://$full_path" unless $full_path =~ /^http/;
    try {

        my @args = ($method, $full_path);
        if ($payload) {
            my $headers = {'Content-Type' => 'application/json'};
            push(
                @args,
                {
                    headers => $headers,
                    content => encode_json_utf8($payload)});
        }

        my $response = $self->http->request(@args);
        my $data     = JSON::MaybeUTF8::decode_json_utf8($response->{content} || '{}');
        return {
            code => $response->{status},
            data => $data
        };
    } catch ($e) {
        die "Request to $path Failed - $e"
    }
}

=head2 get_providers

retrieve a list of providers info from the service.
return an arrayref of result or error string. 

=over 4

=item * C<base_redirect_url> - The base redirect url based on the domain the service hosted in.

=back

=cut

method get_providers ($base_redirect_url) {

    my $path   = "/providers?base_redirect_url=$base_redirect_url";
    my $method = "GET";

    my $result = $self->api_call($method, $path);

    if ($result->{code} != OK_STATUS_CODE) {
        return $result->{data}->{message};
    }

    if ($result->{data}->{data}) {
        return $result->{data}->{data};
    }

    die 'Response does not contain expected result';
}

=head2 retrieve_user_info

the function will send request with cookie and providers params
returns the user email and provider data

=over 4

=item * C<base_redirect_url> - The base redirect url based on the domain the service hosted in.

=back

=cut

method retrieve_user_info {
    my $base_redirect_url = shift;
    my $params            = shift;

    my $path   = "/exchange?base_redirect_url=$base_redirect_url";
    my $method = "POST";

    my $response = $self->api_call($method, $path, $params);

    if ($response->{data}->{data} && $response->{code} == OK_STATUS_CODE) {
        return $response->{data}->{data};
    }
    if ($response->{data}->{error} && $response->{code} == BAD_REQUEST_STATUS_CODE) {
        return $response->{data};
    }

    #error other than BAD_REQUEST e.g. service unavailable.
    if ($response->{data}->{error}) {
        die $response->{data}->{error};
    }

    die "Response does not contain expected result";
}

1;
