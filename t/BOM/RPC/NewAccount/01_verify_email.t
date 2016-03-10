use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Data::Dumper;

use Test::BOM::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase;

use utf8;

my ( $client );
my ( $t, $rpc_ct );
my $method = 'verify_email';

my @params = (
    $method,
    {
        # language => 'RU',
        # source => 1,
        # country => 'ru',
        # args => {
        #     email => 'test@mailinator.com',
        #     type => 'account_opening',
        # },
    }
);

subtest 'Initialization' => sub {
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $client->email('some_email@binary.com');
    } 'Initial client';

    lives_ok {
        $t = Test::Mojo->new('BOM::RPC');
        $rpc_ct = Test::BOM::RPC::Client->new( ua => $t->app->ua );
    } 'Initial RPC server and client connection';
};

subtest 'Return empty client portfolio' => sub {
    $rpc_ct->call_ok(@params)
           ->has_no_system_error
           ->has_no_error
           ->result_is_deeply({ status => 1 }, "It always should return 1, so not to leak client's email");

print Dumper $rpc_ct->response;
};

done_testing();
