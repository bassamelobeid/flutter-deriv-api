use strict;
use warnings;

use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;

use BOM::RPC::v3::Contract;
use Data::Dumper;

subtest 'validate_symbol' => sub{
  is(BOM::RPC::v3::Contract::validate_symbol('R_50'), undef, "return undef if symbol is valid");
  is_deeply(BOM::RPC::v3::Contract::validate_symbol('invalid_symbol'),  {
               'error' => {
                            'message_to_client' => 'Symbol invalid_symbol invalid',
                            'code' => 'InvalidSymbol'
                          }
                                                                         }, 'return error if symbol is invalid'
             );
  ok(1);
};

done_testing();
