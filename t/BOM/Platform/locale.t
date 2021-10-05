use strict;
use warnings;
use Test::More;
use Test::Deep;
use BOM::Platform::Locale;

subtest 'Netherlands' => sub {
    my %states = map { $_->{value} => 1 } @{BOM::Platform::Locale::get_state_option('nl')};
    ok !$states{$_}, "$_ is not included in the list" foreach qw/SX AW BQ1 BQ2 BQ3 CW/;
};

subtest 'France' => sub {
    my %states = map { $_->{value} => 1 } @{BOM::Platform::Locale::get_state_option('fr')};
    ok !$states{$_}, "$_ is not included in the list" foreach qw/BL WF PF PM/;
};

subtest 'Valid state by value' => sub {
    cmp_deeply BOM::Platform::Locale::validate_state('BA', 'id'),
        {
        value => 'BA',
        text  => 'Bali'
        },
        'got correct hash';

    cmp_deeply BOM::Platform::Locale::validate_state('ba', 'id'),
        {
        value => 'BA',
        text  => 'Bali'
        },
        'got correct hash with lowercased state code';
};

subtest 'Valid state by text' => sub {
    cmp_deeply BOM::Platform::Locale::validate_state('Bali', 'id'),
        {
        value => 'BA',
        text  => 'Bali'
        },
        'got correct state hash';

    cmp_deeply BOM::Platform::Locale::validate_state('bali', 'id'),
        {
        value => 'BA',
        text  => 'Bali'
        },
        'got correct hash with lowercased state name';
};

subtest 'Invalid state' => sub {
    cmp_deeply BOM::Platform::Locale::validate_state('Bury', 'id'), undef, 'got undefined if state is invalid for a given country';
};

done_testing;
