package BOM::User::AuditLog;

use strict;
use warnings;
use feature 'state';

use Mojo::Log::JSON;
use Sys::Hostname;
use Date::Utility;
use Path::Tiny;

state $logger = Mojo::Log::JSON->new(
    path           => '/var/log/fixedodds/audit.log',
    level          => 'info',
    default_fileds => {
        hostname     => sub { Sys::Hostname::hostname },
        ip           => sub { $ENV{REMOTE_ADDR} || '' },
        user_agent   => sub { $ENV{HTTP_USER_AGENT} || '' },
        remote_user  => sub { $ENV{REMOTE_USER} || '' },
        http_referer => sub { $ENV{HTTP_REFERER} || '' },
        script_name => $0,
        uri         => sub { $ENV{REQUEST_URI} || '' },
        cf_ipcountry => sub { $ENV{HTTP_CF_IPCOUNTRY} },
    },
);

sub log {    ## no critic (ProhibitBuiltinHomonyms)
    my $log   = shift;
    my $user  = shift || '';
    my $staff = shift || '';
    $logger->info({
        log   => $log,
        user  => $user,
        staff => $staff
    });
    return;
}

1;
