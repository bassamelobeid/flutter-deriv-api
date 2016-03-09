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
subtest 'validate_symbol' => sub {
    is(BOM::RPC::v3::Contract::validate_symbol('R_50'), undef, "return undef if symbol is valid");
    is_deeply(
        BOM::RPC::v3::Contract::validate_symbol('invalid_symbol'),
        {
            'error' => {
                'message_to_client' => 'invalid_symbol 符号无效',
                'code'              => 'InvalidSymbol'
            }
        },
        'return error if symbol is invalid'
    );
};

subtest 'validate_license' => sub {
    is(BOM::RPC::v3::Contract::validate_license('R_50'), undef, "return undef if symbol is is realtime ");

    is_deeply(
        BOM::RPC::v3::Contract::validate_license('JCI'),
        {
            error => {
                message_to_client => '实时报价不可用于JCI',
                code              => 'NoRealtimeQuotes'
            }
        },
        "return error if symbol is not realtime"
    );

};

subtest 'validate_underlying' => sub {
    is_deeply(
        BOM::RPC::v3::Contract::validate_underlying('invalid_symbol'),
        {
            'error' => {
                'message_to_client' => 'invalid_symbol 符号无效',
                'code'              => 'InvalidSymbol'
            }
        },
        'return error if symbol is invalid'
    );

    is_deeply(
        BOM::RPC::v3::Contract::validate_underlying('JCI'),
        {
            error => {
                message_to_client => '实时报价不可用于JCI',
                code              => 'NoRealtimeQuotes'
            }
        },
        "return error if symbol is not realtime"
    );

    is_deeply(BOM::RPC::v3::Contract::validate_underlying('R_50'), {status => 1}, 'status 1 if everything ok');

};

subtest 'prepare_ask' => sub {
  my $p = {
           "proposal"      => 1,
           "subscribe"     => 1,
           "amount"        => "2",
           "basis"         => "payout",
           "contract_type" => "CALL",
           "currency"      => "USD",
           "symbol"        => "R_50",
           "duration"      => "2",
           "duration_unit" => "m"
          };
  diag(Dumper(BOM::RPC::v3::Contract::prepare_ask($p)));
};


done_testing();
