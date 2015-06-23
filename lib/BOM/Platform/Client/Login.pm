## no critic (RequireFilenameMatchesPackage)
## no critic (ValuesAndExpressions::ProhibitCommaSeparatedStatements)

package BOM::Platform::Client;

use strict;
use warnings;

use BOM::Platform::Runtime;
use BOM::Platform::Context qw(localize);
use BOM::Platform::Authorization;

# This is a 'mix-in' of extra subs for BOM::Platform::Client.  It is not a distinct Class.

#######################################
# login the current client object, Returns a hash:
#   { success => 1, token => xxxxx } - or,
#   { error => (e.g.) 'loginid has been suspended' }
#
# optional args:
#   scopes, client_id (i.e. oauth app-id; default 1), expires_in

sub login {
    my ($client, %args) = @_;

    $args{scopes} ||= ['chart', 'price', 'trade', 'password', 'cashier'];
    $args{expires_in} ||= 86400 * (3 * 365.25);    # i.e. approx 3 years!
    $args{issued_at} ||= time;

    my $error;
    if (grep { $client->loginid =~ /^$_/ } @{BOM::Platform::Runtime->instance->app_config->system->suspend->logins}) {
        $error = localize('Login to this account has been temporarily disabled due to system maintenance. Please try again in 30 minutes.');
    } elsif ($client->get_status('disabled')) {
        $error = localize('This account is unavailable. For any questions please contact Customer Support.');
    } else {
        my $result = {%args, success => 1};

        $result->{token} = BOM::Platform::Authorization->issue_token(
            scopes          => $args{scopes},
            client_id       => ($args{client_id} || 1),
            login_id        => $client->loginid,
            expiration_time => $args{issued_at} + $args{expires_in},
        );
        return $result;
    }

    return {error => $error};
}

1;

