#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::Product::ContractFactory qw/produce_contract/;
use Date::Utility;
use BOM::Config::RedisReplicated;
use JSON::MaybeXS qw/decode_json/;

sub get_keys {
    my $r = BOM::Config::RedisReplicated::redis_pricer;
    return $r->keys('*')->@*;
}

sub to_short_code {
    my $x = shift;

    $x =~ s/^PRICER_KEYS:://;
    return unless $x =~ /^\[/;
    my $d = eval {decode_json $x};
    unless ($d) {
        warn "cannot convert: $x ($@)\n";
        return;
    }

    my %h = @$d;
    if (exists $h{short_code}) {
        return [@h{qw/short_code currency/}, 'bid'];
    } else {
        return unless defined $h{duration};
        my $sc = eval {
            produce_contract({
                              underlying => $h{symbol},
                              amount => $h{amount},
                              amount_type => $h{basis},
                              currency => $h{currency},
                              bet_type => $h{contract_type},
                              duration => $h{duration}.$h{duration_unit},
                              ($h{barrier2}
                               ? (
                                  high_barrier => $h{barrier},
                                  low_barrier => $h{barrier2},
                                 )
                               : $h{contract_type} =~ /^LB/
                               ? ()
                               : (
                                  barrier => $h{barrier} // 'S0P',
                                 )
                              )
                             })->shortcode;
        };
        unless ($sc) {
            my $e = $@;
            if (ref $e) {
                $e = "@{[%$e]}";
            }
            warn "cannot convert: $x ($e)\n";
            return;
        }
        return [$sc, $h{currency}, 'ask'];
    }
}

print "$_->[0]\t$_->[1]\t$_->[2]\n"
    for (map {to_short_code $_} get_keys);
