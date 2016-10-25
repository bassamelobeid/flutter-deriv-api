package BOM::Backoffice::Request;

use feature 'state';

our @EXPORT_OK = qw(request localize);

use BOM::Platform::Runtime;
use BOM::Platform::Context::I18N;

state $current_request;

sub request {
    my $new_request = shift;
    state $default_request = BOM::Backoffice::Request::Base->new();
    $current_request = _configure_for_request($new_request) if ($new_request);
    return $current_request // $default_request;
}

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

# need to update this sub to get language as input, as of now
# language is always EN for backoffice
sub localize {
    my @texts = @_;

    my $request = request();
    my $language = $request ? $request->language : 'EN';

    my $lh = BOM::Platform::Context::I18N::handle_for($language)
        || die("could not build locale for language $language");

    return $lh->maketext(@texts);
}

1;
