package BOM::StaffPages;
use strict;
use warnings;

use MooseX::Singleton;
use URI;

use BOM::Backoffice::Request;
use BOM::Backoffice::PlackHelpers 'http_redirect';
use BOM::Backoffice::Auth0;
use BOM::Backoffice::Auth;
use BOM::Config;

sub login {
    my $self = shift;

    if (BOM::Backoffice::Auth0::is_disabled()) {
        if (BOM::Backoffice::Auth::get_authorization_token() and not BOM::Backoffice::Auth::get_staff()) {
            http_redirect(request()->url_for("backoffice/login.cgi"));
        } else {
            print '<script>window.location = "' . BOM::Backoffice::Auth::logout_url() . '" </script>';
            code_exit_BO();
        }
    } else {
        my $clientId = BOM::Config::third_party()->{auth0}->{client_id};
        my $redirect = BOM::Backoffice::Request::request()->url_for('backoffice/second_step_auth.cgi');

        my $auth = URI->new(BOM::Config::third_party()->{auth0}->{api_uri} . '/authorize');
        $auth->query_form(
            response_type => 'code',
            client_id     => $clientId,
            redirect_uri  => $redirect
        );

        http_redirect $auth->as_string;
    }
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

