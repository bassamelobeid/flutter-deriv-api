#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use BOM::Platform::Locale;

my $list;
lives_ok(sub { $list = BOM::Platform::Locale::generate_residence_countries_list(); }, 'generate residence countries list');
is($list->[0]{text}, 'Select Country', 'has prompt');
ok(scalar(grep { defined $_->{disabled} } @$list), 'has disabled');

done_testing();
