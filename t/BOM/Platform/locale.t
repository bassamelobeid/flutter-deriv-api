use strict;
use warnings;
use Test::More;
use BOM::Platform::Locale;

subtest 'Netherlands' => sub {
    my %states = map { $_->{value} => 1 } @{BOM::Platform::Locale::get_state_option('nl')};
    ok !$states{$_}, "$_ is not included in the list" foreach qw/SX AW BQ1 BQ2 BQ3 CW/;
};

subtest 'France' => sub {
    my %states = map { $_->{value} => 1 } @{BOM::Platform::Locale::get_state_option('fr')};
    ok !$states{$_}, "$_ is not included in the list" foreach qw/BL WF PF PM/;
};

done_testing;
