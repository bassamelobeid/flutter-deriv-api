package BOM::Backoffice::Request;

use feature 'state';

our @EXPORT_OK = qw(request);

use BOM::Platform::Runtime;

state $current_request;

=head2 get_request

The object representing the current request.

Current request is set by passing in a new I<BOM::Platform::Request> object.

returns,
    An instance of BOM::Platform::Context::Request. current request if its set or default values if its not set.

=cut

sub request {
    my $new_request = shift;
    state $default_request = BOM::Platform::Request::Base->new();
    $current_request = _configure_for_request($new_request) if ($new_request);
    return $current_request // $default_request;
}

=head2 request_completed

Marks completion of the request.

=cut

sub request_completed {
    $current_request = undef;
    _configure_for_request(request());
    return;
}

sub _configure_for_request {
    my $request = shift;
    BOM::Platform::Runtime->instance->app_config->check_for_update();
    return $request;
}

1;
