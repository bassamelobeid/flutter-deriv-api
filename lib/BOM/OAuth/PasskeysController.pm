package BOM::OAuth::PasskeysController;

use strict;
use warnings;
use Log::Any qw( $log );
use Mojo::Base 'Mojolicious::Controller';
use Syntax::Keyword::Try;
use BOM::Config::Redis;
use BOM::OAuth::Helper qw(request_details_string exception_string);
use BOM::OAuth::Passkeys::PasskeysService;

=head2 passkeys_service

Caches & Returns the cached passkeys service instance.
The service will be available for one request only as the controller will be destroyed after the request is done.

=cut

sub passkeys_service {
    my $self = shift;
    return $self->{passkeys_service} //= BOM::OAuth::Passkeys::PasskeysService->new;
}

=head2 get_options

Returns a json response contains the passkeys options.
We need to rate limit this endpoint.

=cut

sub get_options {
    my $self = shift;
    try {
        my $options = $self->passkeys_service->get_options;
        return $self->render(
            json   => $options,
            status => 200
        );
    } catch ($e) {
        $log->error($self->_to_error_message($e, "Failed to get passkeys options"));
        return $self->_render_error;
    }
}

# Error codes produced by the controller and corresponding messages.
# Can be moved to Static.pm if needed.

my $ERROR_CODES = {
    InternalServerError => "Sorry, an error occurred while processing your request.",
};

=head2 _render_error

Renders an error response with the given error code and status.
similar to _make_error in BOM::OAuth::RestAPI.

=over 4

=item * $error_code - The error code to return.

=item * $status - The status code to return.

=item * $details - Optional. Additional details to return.

=back

=cut

sub _render_error {
    my ($self, $error_code, $status, $details) = @_;
    $error_code //= 'InternalServerError';

    $self->render(
        json => {
            error_code => $error_code,
            message    => $ERROR_CODES->{$error_code},
            ($details ? (details => $details) : ()),
        },
        status => $status // 500
    );
}

=head2 _to_error_message

Returns a string representing passkeys login exception with the possibility of providing additional info.
It'll append the request details. 

=over 4

=item * $exception - The exception object.

=item * $message - Optional. Additional message to append.

=back

=cut

sub _to_error_message {
    my ($self, $exception, $message) = @_;

    my $exception_message = exception_string($exception);
    my $request_details   = request_details_string($self->req, $self->stash('request'));
    my $result            = "Passkeys exception - ";
    if ($message) {
        $result .= "$message - ";
    }
    $result .= "$exception_message while processing $request_details";
    return $result;
}

1;
