use strict;
use warnings;

use Test::Most tests => 9;
use Test::Warnings;
use Test::Deep;
use Test::Exception;
use Finance::Contract::Category;

subtest 'Attribute test for unknown code' => sub {
    my $unknown = Finance::Contract::Category->new('unknown');
    is($unknown->code,          'unknown', 'Correct code');
    is($unknown->display_name,  undef,     'Correct display name');
    is($unknown->display_order, undef,     'Correct display order');
    is($unknown->explanation,   undef,     'Correct explanation');
};

subtest 'callput' => sub {
    my $cat = Finance::Contract::Category->new('callput');
    is $cat->code,          'callput';
    is $cat->display_order, 1;
    is $cat->display_name,  'Up/Down';
    ok !$cat->is_path_dependent;
    ok $cat->barrier_at_start, 'barrier determined at start';
    is_deeply $cat->supported_expiries, ['intraday', 'daily', 'tick'];
    cmp_bag $cat->available_types, ['CALL', 'PUT'];
};

subtest 'callputequal' => sub {
    my $cat = Finance::Contract::Category->new('callputequal');
    is $cat->code,          'callputequal';
    is $cat->display_order, 2;
    is $cat->display_name,  'Rise/Fall Equal';
    ok !$cat->is_path_dependent;
    ok $cat->barrier_at_start, 'barrier determined at start';
    is_deeply $cat->supported_expiries, ['intraday', 'daily', 'tick'];
    cmp_bag $cat->available_types, ['CALLE', 'PUTE'];
};

subtest 'asian' => sub {
    my $cat = Finance::Contract::Category->new('asian');
    is $cat->code,          'asian';
    is $cat->display_order, 7;
    is $cat->display_name,  'Asians';
    ok !$cat->is_path_dependent;
    ok !$cat->barrier_at_start, 'barrier determined at expiry';
    is_deeply $cat->supported_expiries, ['tick'];
    cmp_bag $cat->available_types,      ['ASIANU', 'ASIAND'];
};

subtest 'digits' => sub {
    my $cat = Finance::Contract::Category->new('digits');
    is $cat->code,          'digits';
    is $cat->display_order, 6;
    is $cat->display_name,  'Digits';
    ok !$cat->is_path_dependent;
    ok $cat->barrier_at_start, 'barrier determined at start';
    is_deeply $cat->supported_expiries, ['tick'];
    cmp_bag $cat->available_types,      ['DIGITMATCH', 'DIGITDIFF', 'DIGITODD', 'DIGITEVEN', 'DIGITOVER', 'DIGITUNDER'];
};

subtest 'touchnotouch' => sub {
    my $cat = Finance::Contract::Category->new('touchnotouch');
    is $cat->code,          'touchnotouch';
    is $cat->display_order, 3;
    is $cat->display_name,  'Touch/No Touch';
    ok $cat->is_path_dependent;
    ok $cat->barrier_at_start, 'barrier determined at start';
    is_deeply $cat->supported_expiries, ['intraday', 'daily', 'tick'];
    cmp_bag $cat->available_types, ['ONETOUCH', 'NOTOUCH'];
};

subtest 'endsinout' => sub {
    my $cat = Finance::Contract::Category->new('endsinout');
    is $cat->code,          'endsinout';
    is $cat->display_order, 4;
    is $cat->display_name,  'Ends Between/Ends Outside';
    ok !$cat->is_path_dependent;
    ok $cat->barrier_at_start, 'barrier determined at start';
    is_deeply $cat->supported_expiries, ['intraday', 'daily'];
    cmp_bag $cat->available_types, ['EXPIRYRANGE', 'EXPIRYMISS', 'EXPIRYMISSE', 'EXPIRYRANGEE'];
};

subtest 'staysinout' => sub {
    my $cat = Finance::Contract::Category->new('staysinout');
    is $cat->code,          'staysinout';
    is $cat->display_order, 5;
    is $cat->display_name,  'Stays Between/Goes Outside';
    ok $cat->is_path_dependent;
    ok $cat->barrier_at_start, 'barrier determined at start';
    is_deeply $cat->supported_expiries, ['intraday', 'daily'];
    cmp_bag $cat->available_types,      ['RANGE',    'UPORDOWN'];
};
