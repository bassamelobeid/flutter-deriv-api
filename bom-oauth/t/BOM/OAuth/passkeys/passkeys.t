use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Mojo;
use Test::MockModule;

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
                    code    => 'WrongResponse',
                    message => 'message'
                };
            });
        $t->get_ok('/api/v1/passkeys/login/options')->status_is(500);
        my $json = $t->tx->res->json;
        is($json->{error_code}, 'PASSKEYS_SERVICE_ERROR', 'Error code exists');
    };

    subtest 'passkeys returns error object for UserNotFound' => sub {
        $mock_passkeys_client->mock(
            'passkeys_options' => sub {
                die {
                    code    => 'UserNotFound',
                    message => 'User not found'
                };
            });

        $t->get_ok('/api/v1/passkeys/login/options')->status_is(400);

        my $json = $t->tx->res->json;
        is($json->{error_code}, 'PASSKEYS_NOT_FOUND', 'Error code exists');
    };
};

done_testing();
