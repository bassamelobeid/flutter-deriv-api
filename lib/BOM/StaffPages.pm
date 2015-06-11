package BOM::StaffPages;

use MooseX::Singleton;
use Data::Dumper;
use BOM::Platform::Context;
use BOM::System::Config;

sub login {
    my $self   = shift;
    my $bet    = shift;
    my $params = {};
    my $clientId = BOM::System::Config::third_party->{auth0}->{client_id};

    $params->{submit}   = BOM::Platform::Context::request()->url_for('backoffice/second_step_auth.cgi');
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
    <form id='auth-form' name='second_step_auth' action='$params->{submit}'>
    <input type='hidden' id='auth0-token' name='token' />
    </form>
    <script src="https://cdn.auth0.com/js/lock-7.min.js"></script>
    <script>
    var lock = new Auth0Lock('$clientId', 'binary.auth0.com');
      lock.show(function onLogin(err, profile, id_token, access_token) {
        document.getElementById("auth-form").method = "post";
        document.getElementById("auth0-token").value = access_token;
        document.second_step_auth.submit();
      });
    </script>
    </html>
    ~;

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
