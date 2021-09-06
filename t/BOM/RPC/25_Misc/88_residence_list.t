#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::More;
use Test::Exception;
use BOM::RPC::v3::Static;
use Email::Stuffer::TestLinks;

my $list;
lives_ok(sub { $list = BOM::RPC::v3::Static::residence_list(); }, 'generate residence countries list');
ok(scalar(grep { defined $_->{disabled} } @$list), 'has disabled');

done_testing();
