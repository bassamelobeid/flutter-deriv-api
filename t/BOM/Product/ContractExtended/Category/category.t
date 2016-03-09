use strict;
use warnings;

use Test::Most tests => 8;
use Test::NoWarnings;
use Test::Exception;
use BOM::Product::Contract::Category;

subtest 'Attribute test for unknown code' => sub {
    my $unknown = BOM::Product::Contract::Category->new('unknown');
    is($unknown->code,          'unknown', 'Correct code');
    is($unknown->display_name,  undef,     'Correct display name');
    is($unknown->display_order, undef,     'Correct display order');
    is($unknown->explanation,   undef,     'Correct explanation');
};

subtest 'callput' => sub {
    my $cat = BOM::Product::Contract::Category->new('callput');
    is $cat->code,          'callput';
    is $cat->display_order, 1;
    is $cat->display_name,  'Up/Down';
    ok !$cat->is_path_dependent;
    is_deeply $cat->supported_expiries, ['intraday', 'daily', 'tick'];
    is_deeply $cat->supported_start_types, ['spot', 'forward'];
    cat_type_match($cat);
};

subtest 'asian' => sub {
    my $cat = BOM::Product::Contract::Category->new('asian');
    is $cat->code,          'asian';
    is $cat->display_order, 6;
    is $cat->display_name,  'Asians';
    ok !$cat->is_path_dependent;
    is_deeply $cat->supported_expiries,    ['tick'];
    is_deeply $cat->supported_start_types, ['spot'];
    cat_type_match($cat);
};

subtest 'digits' => sub {
    my $cat = BOM::Product::Contract::Category->new('digits');
    is $cat->code,          'digits';
    is $cat->display_order, 5;
    is $cat->display_name,  'Digits';
    ok !$cat->is_path_dependent;
    is_deeply $cat->supported_expiries,    ['tick'];
    is_deeply $cat->supported_start_types, ['spot'];
    cat_type_match($cat);
};

subtest 'touchnotouch' => sub {
    my $cat = BOM::Product::Contract::Category->new('touchnotouch');
    is $cat->code,          'touchnotouch';
    is $cat->display_order, 2;
    is $cat->display_name,  'Touch/No Touch';
    ok $cat->is_path_dependent;
    is_deeply $cat->supported_expiries, ['intraday', 'daily'];
    is_deeply $cat->supported_start_types, ['spot'];
    cat_type_match($cat);
};

subtest 'endsinout' => sub {
    my $cat = BOM::Product::Contract::Category->new('endsinout');
    is $cat->code,          'endsinout';
    is $cat->display_order, 3;
    is $cat->display_name,  'Ends In/Out';
    ok !$cat->is_path_dependent;
    is_deeply $cat->supported_expiries, ['intraday', 'daily'];
    is_deeply $cat->supported_start_types, ['spot'];
    cat_type_match($cat);
};

subtest 'staysinout' => sub {
    my $cat = BOM::Product::Contract::Category->new('staysinout');
    is $cat->code,          'staysinout';
    is $cat->display_order, 4;
    is $cat->display_name,  'Stays In/Goes Out';
    ok $cat->is_path_dependent;
    is_deeply $cat->supported_expiries, ['intraday', 'daily'];
    is_deeply $cat->supported_start_types, ['spot'];
    cat_type_match($cat);
};

sub cat_type_match {
    my $cat = shift;

    subtest 'Available types' => sub {
        foreach my $class_name (@{$cat->available_types}) {
            use_ok($class_name);
            is $class_name->category_code, $cat->code, 'correctly sorted.';
        }
    };
}

