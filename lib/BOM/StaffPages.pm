package BOM::StaffPages;

use MooseX::Singleton;
use Data::Dumper;
use BOM::Platform::Context;

sub login {
    my $self   = shift;
    my $bet    = shift;
    my $params = {};

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
    <html><link rel="stylesheet" href="https://maxcdn.bootstrapcdn.com/bootstrap/3.3.4/css/bootstrap.min.css">
    <title>Binary.com BackOffice System</title>

    <body><form action="$params->{submit}" method="POST">
    <table align="center">
    <tr><td><h1>BackOffice Login</h1></td></tr>

    <tr><td><div class="form-group">
      <label for="userEmail">Email address</label>
      <input type="email" class="form-control" name="email" id="userEmail" placeholder="Enter email">
    </div></td></tr>

    <tr><td><div class="form-group">
      <label for="userPassword">Password</label>
      <input type="password" class="form-control" name="password" id="userPassword" placeholder="Password">
    </div></td></tr>

    <tr><td><input type="submit" value="Sign in Binary.com BackOffice" class="btn btn-default"></td></tr>
    <tr><td><br /><br />
    To reset password, go <a href="https://manage.auth0.com/login">here</a> and click reset password
    </td></tr>
    </table>
    </form></body>
    </html>
    ~;

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
