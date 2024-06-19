use strict;
use warnings;

use Test::More;
use BOM::Test::LocalizeSyntax;
use Path::Tiny;
use Test::MockModule;

isa_ok(BOM::Test::LocalizeSyntax::_get_locale_extract(), 'Locale::Maketext::Extract', '_get_locale_extract get correct object');
my $mock = Test::MockModule->new('BOM::Test::LocalizeSyntax');
my @log_fail_args;
$mock->mock('_log_fail', sub { push @log_fail_args, \@_ });

my $tested_pm = path('/tmp/dummy.pm');
$tested_pm->spew(<<'EOF');
package Dummy;

my $name = "Jack";
localize("hello, world");
localize("hello [_1]", $name);
localize("hello $name");
localize("hello _1", $name);
EOF

my $tested_t = $tested_pm->copy('/tmp/dummy.t');
my ($entries, $passed_count) = BOM::Test::LocalizeSyntax::do_test($tested_pm, $tested_t);
my ($dump_entries) = explain($entries);
is(scalar(keys %$entries), 4, '4 strings tested');
like($dump_entries, qr/dummy.pm/, "dummy.pm tested");
unlike($dump_entries, qr/dummy.pl/, 'dummy.pl not tested');
is($passed_count, 2, "2 lines passed");
my $expected_result = [
    ['Should not start with space nor should have any direct variable.', 'hello $name', [[$tested_pm, 6, undef]]],
    ['Should not contain field names. Please use placeholder instead.',  'hello _1',    [[$tested_pm, 7, ', $name']]]

];
is_deeply(\@log_fail_args, $expected_result, "failed message ok");
done_testing;
