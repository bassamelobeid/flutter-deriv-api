use strict;
use warnings;

use lib qw!/etc/perl
    /home/git/regentmarkets/cpan/local/lib/perl5
    /home/git/regentmarkets/cpan/local/lib/perl5/x86_64-linux-gnu-thread-multi
    /home/git/bom/lib
    /home/git/regentmarkets/bom-paymentapi/lib
    /home/git/bom/database/lib!;

use Plack::Builder;

use BOM::API::Payment;

my $alog;
if ($ENV{ACCESS_LOG}) {
    open $alog, '>>', $ENV{ACCESS_LOG}    ## no critic
        or die "Cannot open access_log: $!";
    select +(select($alog), $| = 1)[0];    ## no critic
}

builder {
    enable 'AccessLog::Timed' => (
        format => '%h %l %u %t "%r" %>s %b %D',
        logger => sub { local $\; print $alog $_[0] },
    ) if $alog;

    enable sub {
        my $app = shift;
        sub {
            my $env = shift;
            my $res = $app->($env);
            if (ref $res->[2] eq 'ARRAY' and         # response is ready
                $res->[0] ne '204' and               # it's not NO CONTENT
                $res->[0] ne '304' and               # it's not NOT MODIFIED
                substr($res->[0], 0, 1) ne '1') {    # it's not a intermediate response code
                # loop through headers to see if there is a content-length
                for (my $i = 0; $i < @{$res->[1]}; $i += 2) {
                    return $res if lc($res->[1]->[$i]) eq 'content-length';
                }
                # no content-length so far;
                my $cl = 0;
                foreach my $chunk (@{$res->[2]}) {
                    $cl += length $chunk;
                }
                push @{$res->[1]}, 'Content-Length' => $cl;
            }
            return $res;
        };
    };

    BOM::API::Payment->to_app();
};
