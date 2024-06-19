use strict;
use warnings;
use Test::More (tests => 14);
use Test::Warnings;
use Test::Exception;
use Date::Utility;
use BOM::Database::Model::HandoffToken;
use BOM::Database::ClientDB;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $connection_builder;
my $handoff_token;
my $handoff_token_key = BOM::Database::Model::HandoffToken::generate_session_key();
my $expiry            = time + 50;

lives_ok {
    $connection_builder = BOM::Database::ClientDB->new({
        broker_code => 'CR',
    });

    $handoff_token = BOM::Database::Model::HandoffToken->new({
            data_object_params => {
                key            => $handoff_token_key,
                client_loginid => 'CR5063',
                expires        => $expiry,
            },
            db => $connection_builder->db
        });
    $handoff_token->save;
}
'expecting to load the required handoff_token models for transfer';

isa_ok($handoff_token->class_orm_record, 'BOM::Database::AutoGenerated::Rose::HandoffToken');

lives_ok {
    $handoff_token = BOM::Database::Model::HandoffToken->new({
        data_object_params => {key => $handoff_token_key},
        db                 => $connection_builder->db
    });
    $handoff_token->load;
}
'expect to load handoff_token ';

cmp_ok($handoff_token->handoff_token_record->key,            'eq', $handoff_token_key, 'Check if it load the handoff_token properly');
cmp_ok($handoff_token->key,                                  'eq', $handoff_token_key, 'key comes through Model');
cmp_ok($handoff_token->handoff_token_record->client_loginid, 'eq', 'CR5063',           'correct loginid?');
cmp_ok($handoff_token->client_loginid,                       'eq', 'CR5063',           'loginid comes through the Model');
cmp_ok($handoff_token->handoff_token_record->client_loginid, 'eq', 'CR5063',           'correct loginid?');
cmp_ok($handoff_token->client_loginid,                       'eq', 'CR5063',           'loginid comes through the Model');
cmp_ok($handoff_token->handoff_token_record->expires->epoch, 'eq', $expiry,            'correct expiry?');
cmp_ok($handoff_token->expires->epoch,                       'eq', $expiry,            'expiry');
is($handoff_token->exists,   1, 'handoff_token exists before validation');
is($handoff_token->is_valid, 1, 'handoff_token is still valid');

exit 0;

END {
    $handoff_token = BOM::Database::Model::HandoffToken->new({
        db                 => $connection_builder->db,
        data_object_params => {key => $handoff_token_key},
    });
    if ($handoff_token->load({load_params => {speculative => 1}})) {
        $handoff_token->delete;
    }
}

__DATA__

