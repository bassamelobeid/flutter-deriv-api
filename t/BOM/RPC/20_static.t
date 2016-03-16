use strict;
use warnings;

use utf8;
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use Data::Dumper;

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
subtest 'residence_list' => sub{
  diag Dumper ($c->call_ok('residence_list',params => {})->has_no_system_error->result);
  ok(1);
};

done_testing();
