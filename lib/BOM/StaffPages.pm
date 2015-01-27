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

    BOM::Platform::Context::template->process('backoffice/staff/login.html.tt', $params);

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
