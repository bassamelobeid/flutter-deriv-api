package Plack::Middleware::Auth::DoughFlow;

use strict;
use warnings;
use parent                qw(Plack::Middleware);
use Plack::Util::Accessor qw( secret_key header_name acceptable_time_diff continue_on_fail );
use Plack::Request;
use Digest::MD5 qw/md5_hex/;

sub call {
    my ($self, $env) = @_;

    {
        my $header_name = $self->header_name || 'X-DoughFlow-Authorization';
        my $req         = Plack::Request->new($env);
        my $auth        = $req->header($header_name) || last;
        my $log         = $env->{log};

        last unless $auth =~ /^(\d+):([a-f0-9]+)$/i;

        my ($timestamp, $hash) = ($1, $2);

        ## validate timestamp
        my $acceptable_time_diff = $self->acceptable_time_diff || 60;
        last if abs(time() - $timestamp) > $acceptable_time_diff;

        ## validate hash
        my $calc_hash = Digest::MD5::md5_hex($timestamp . $self->secret_key);
        $calc_hash = substr($calc_hash, length($calc_hash) - 10, 10);
        last unless $hash eq $calc_hash;

        ## all good
        $env->{'X-DoughFlow-Authorization-Passed'} = 1;
        $log->debug("able to set authorization header");
        return $self->app->($env);
    }

    return $self->app->($env) if $self->continue_on_fail;    # fallback to Auth::Basic if you want
    return [401, [], ['Authorization required']];
}

1;
