use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Mojo;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

use JSON::MaybeUTF8 qw(:v1);

use BOM::OAuth::PasskeysController;

my $mock_passkeys_client = Test::MockModule->new('BOM::OAuth::Passkeys::PasskeysClient');

my $t = Test::Mojo->new('BOM::OAuth');

subtest 'passkeys options' => sub {
    subtest 'passkeys returns options object with 200 status' => sub {
        $mock_passkeys_client->mock(
            'passkeys_options' => sub {
                return {
                    publicKey => 'test',
                };
            });
        $t->get_ok('/api/v1/passkeys/login/options')->status_is(200);
        my $json = $t->tx->res->json;
        is($json->{publicKey}, 'test', 'publicKey exists');

    };

    subtest 'passkeys returns error object with 500 status' => sub {
        $mock_passkeys_client->mock(
            'passkeys_options' => sub {
                die {
                    code    => 'error',
                    message => 'message'
                };
            });
        $t->get_ok('/api/v1/passkeys/login/options')->status_is(500);
        my $json = $t->tx->res->json;
        is($json->{error_code}, 'InternalServerError', 'Error code exists');
    };
};

done_testing();
