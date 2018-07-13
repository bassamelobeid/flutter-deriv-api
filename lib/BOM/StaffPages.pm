package BOM::StaffPages;
use strict;
use warnings;

use MooseX::Singleton;
use Data::Dumper;
use BOM::Backoffice::Request;
use BOM::Config;

sub login {
    my $self     = shift;
    my $bet      = shift;
    my $params   = {};
    my $clientId = BOM::Config::third_party()->{auth0}->{client_id};

    $params->{submit}   = BOM::Backoffice::Request::request()->url_for('backoffice/second_step_auth.cgi');
    $params->{bet}      = $bet;
    $params->{redirect} = '';
    if ($main::ENV{'SCRIPT_NAME'} =~ /.*\/(.*)$/) {
        my $script = $1;
        unless ($script eq 'f_broker_login.cgi') {
            $params->{redirect} = '';
        }
    }

    print qq~
    <!doctype html>
    <title>Binary.com BackOffice System</title>
    <html>
    <div id="root"></div>
    <script src="https://cdn.auth0.com/js/lock/11.7.2/lock.min.js"></script>
    <script>
    var lock = new Auth0Lock('$clientId', 'binary.auth0.com', {
      auth: {
        redirectUrl: '$params->{submit}',
        responseMode: 'form_post',
        responseType: 'code',
        sso: false,
      }
    });
    lock.show();
    </script>
    </html>
    ~;

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
