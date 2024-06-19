package BOM::StaffPages;
use strict;
use warnings;

use MooseX::Singleton;

use BOM::Backoffice::PlackHelpers 'http_redirect';
use BOM::Backoffice::Auth;

sub login {
    if (BOM::Backoffice::Auth::get_authorization_token() and not BOM::Backoffice::Auth::get_staff()) {
        http_redirect(request()->url_for("backoffice/login.cgi"));
    } else {
        print '<script>window.location = "' . BOM::Backoffice::Auth::logout_url() . '" </script>';
        code_exit_BO();
    }
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

