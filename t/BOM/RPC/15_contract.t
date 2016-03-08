use strict;
use warnings;
use utf8;
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;

use BOM::RPC::v3::Contract;
use BOM::Platform::Context qw (request);
use Data::Dumper;
request(BOM::Platform::Context::Request->new(params => {l => 'ZH_CN'}));
subtest 'validate_symbol' => sub{
  is(BOM::RPC::v3::Contract::validate_symbol('R_50'), undef, "return undef if symbol is valid");
  is_deeply(BOM::RPC::v3::Contract::validate_symbol('invalid_symbol'),  {
               'error' => {
                            'message_to_client' => 'invalid_symbol 符号无效',
                            'code' => 'InvalidSymbol'
                          }
                                                                         }, 'return error if symbol is invalid'
             );
};

subtest 'validate_license' => sub {
  is(BOM::RPC::v3::Contract::validate_license('R_50'), undef, "return undef if symbol is is realtime ");
  
  is_deeply(BOM::RPC::v3::Contract::validate_license('FUTHSI_BOM'),{error => {message_to_client => '实时报价不可用于FUTHSI_BOM', code => 'NoRealtimeQuotes'}}, "return error if symbol is realtime");
  
};



done_testing();
