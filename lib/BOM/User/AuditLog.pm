package BOM::User::AuditLog;

use strict;
use warnings;

use Sys::Hostname;
use Encode;
use JSON::MaybeXS;
use Date::Utility;
use Path::Tiny;

my $json = JSON::MaybeXS->new;

sub log {    ## no critic (ProhibitBuiltinHomonyms)
    my $log   = shift;
    my $user  = shift || '';
    my $staff = shift || '';

    Path::Tiny::path('/var/log/fixedodds/audit.log')->append(
        # UTF-8 bytes, in case message or staff/user include non-ASCII chars
        Encode::encode_utf8(
            $json->encode({
                    timestamp    => Date::Utility->new->datetime_iso8601,
                    hostname     => Sys::Hostname::hostname,
                    staff        => $staff,
                    user         => $user,
                    ip           => $ENV{REMOTE_ADDR}     || '',
                    user_agent   => $ENV{HTTP_USER_AGENT} || '',
                    remote_user  => $ENV{REMOTE_USER}     || '',
                    http_referer => $ENV{HTTP_REFERER}    || '',
                    script_name  => $0,
                    uri          => $ENV{REQUEST_URI} || '',
                    log          => $log,
                    cf_ipcountry => $ENV{HTTP_CF_IPCOUNTRY},
                }))
            . "\n"
    );
    return;
}

1;
