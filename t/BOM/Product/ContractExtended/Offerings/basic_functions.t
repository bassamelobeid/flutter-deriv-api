#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::MockModule;
use File::Spec;

use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use Test::More (tests => 6);
use Test::Warnings;
use Test::Exception;
use Test::Differences;

use List::MoreUtils qw( all none );

use BOM::Product::Offerings::DisplayHelper;
use LandingCompany::Registry;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'partial_trading',
    {
        type          => 'early_closes',
        recorded_date => Date::Utility->new('2020-01-01'),
        calendar      => {
            '03-Jul-2020' => {
                '15h00m' => ['METAL'],
            },
        },
    });

my $o = LandingCompany::Registry::get('svg')->basic_offerings({
    loaded_revision => 0,
    action          => 'buy'
});
my $expected_levels = 4;
my $offerings = new_ok('BOM::Product::Offerings::DisplayHelper' => [{offerings => $o}]);

my $original_levels = $offerings->levels;
subtest levels => sub {
    plan tests => 2;

    isa_ok($original_levels, 'ARRAY');
    is(scalar @$original_levels, $expected_levels, "..with our expected $expected_levels levels of info");
};
my $original_tree = $offerings->tree;

subtest 'tree and get_items_on_level' => sub {
    plan tests => $expected_levels + 1;

    isa_ok($original_tree, 'ARRAY');
    foreach my $level (@$original_levels) {
        my $level_items = $offerings->get_items_on_level($level);
        isa_ok($level_items, 'ARRAY');
    }
};

subtest 'decorate_tree' => sub {
    my $fake_level      = 'malebolge';
    my $decoration_name = 'tinsel';
    throws_ok {
        $offerings->decorate_tree(
            $fake_level => {
                $decoration_name => sub { 1; }
            });
    }
    qr/must match one of those/, 'Trying to decorate a level which does not exist ("' . $fake_level . '") fails';
    note "If $expected_levels < 2, you're going to have a bad time.";
    my $top_level    = $original_levels->[0];
    my $second_level = $original_levels->[1];
    lives_ok {
        $offerings->decorate_tree(
            $top_level => {
                $decoration_name => sub { 'hi'; }
            });
    }
    'Decorating "' . $top_level . '" works fine';
    my $top_level_items = $offerings->get_items_on_level($top_level);
    ok((all { exists $_->{$decoration_name} } (@$top_level_items)),
        '.. decorations called ' . $decoration_name . ' now exist on the "' . $top_level . '" level items');
    my $second_level_items = $offerings->get_items_on_level($second_level);
    ok((none { exists $_->{$decoration_name} } (@$second_level_items)),
        '.. decorations called ' . $decoration_name . ' do not exist on any of the "' . $second_level . '" level items');

    eq_or_diff($offerings->tree, $original_tree, "Asking for the tree again produces the decorated_tree");
    my $new_offerings = new_ok('BOM::Product::Offerings::DisplayHelper', [{offerings => $o}]);
    isnt($new_offerings->tree, $original_tree, "..but asking the new copy does not have the decorations.");
};

subtest 'Early close dates on Fridays' => sub {
    my $tree = BOM::Product::Offerings::DisplayHelper->new(
        date      => Date::Utility->new('2020-07-03'),
        offerings => $o
        )->decorate_tree(
        markets     => {name => 'name'},
        submarkets  => {name => 'name'},
        underlyings => {
            name   => 'name',
            times  => 'times',
            events => 'events',
        });

    is_deeply(
        $tree->[2]{submarkets}[0]{underlyings}[0]{events},
        [{
                'dates'   => '2020-07-03',
                'descrip' => 'Closes early (at 15:00)'
            },
            {
                'dates'   => 'Fridays',
                'descrip' => 'Closes early (at 20:55)'
            }
        ],
        'Early close on Fridays is shown with date'
    );
};

1;
