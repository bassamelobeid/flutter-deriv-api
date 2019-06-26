use strict;
use warnings;
use Test::Most;
use JSON::MaybeXS;
use Path::Tiny;

# This test checks we don't return passwords in any response schemas

my $json       = JSON::MaybeXS->new;
my $SCHEMA_DIR = '/home/git/regentmarkets/binary-websocket-api/config/v3/';

for my $call_name (path($SCHEMA_DIR)->children) {
    next if $call_name =~ /draft-03/;
    my $contents = path("$call_name/receive.json")->slurp_utf8;
    my $props    = $json->decode($contents)->{properties};
    my @els      = check($props);
    ok(!@els, path($call_name)->basename . " schema has no string properties potentially containing passwords")
        or diag("Property name(s): @els");
}

sub check {
    my ($props) = @_;
    my @els;
    for my $k (keys %$props) {
        if (exists $props->{$k}{type} && $props->{$k}{type} eq 'string' && $k =~ /^password$/i) {
            push @els, $k;
        } elsif (exists $props->{$k}{properties}) {
            push @els, check($props->{$k}{properties});
        }
    }
    return @els;
}

done_testing();
