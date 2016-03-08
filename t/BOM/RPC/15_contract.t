use strict;
use warnings;

use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;

use BOM::RPC::v3::Contract;
use Data::Dumper;

subtest 'validate_symbol' => sub{
  diag(Dumper(BOM::RPC::v3::Contract::validate_symbol('R_50')));
  ok(1);
};

done_testing();
