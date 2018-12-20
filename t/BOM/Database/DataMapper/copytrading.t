use strict;
use warnings;
use Test::More;

use Test::Exception;
use BOM::Database::Model::Account;

use BOM::Database::Model::Account;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::ClientDB;
use BOM::Database::AutoGenerated::Rose::Copier::Manager;

use BOM::Database::AutoGenerated::Rose::Copier;

use BOM::Database::DataMapper::Copier qw| get_copiers_count get_traders |;
use BOM::Database::Model::AccessToken;

my $connection_builder;
my $accounts = {};

my $token_db = BOM::Database::Model::AccessToken->new;

lives_ok {
    $connection_builder = BOM::Database::ClientDB->new({
        broker_code => 'CR',
    });
    for (27 .. 29) {
        my $loginid = 'CR00' . $_;
        $accounts->{$loginid} = BOM::Database::Model::Account->new({
                'data_object_params' => {
                    'client_loginid' => $loginid,
                    'currency_code'  => 'USD'
                },
                db => $connection_builder->db
            });
        $accounts->{$loginid}->load();
    }

}
'build connection builder & account';

# CR0027 is always the trader in these tests
my $trader_token = $token_db->create_token('CR0027', 'token1', ['read', 'trade', 'payments', 'admin']);

sub subscribe {
    my $args = shift;
    lives_ok {
        BOM::Database::AutoGenerated::Rose::Copier::Manager->delete_copiers(
            db => BOM::Database::ClientDB->new({
                    broker_code => 'CR',
                    operation   => 'write',
                }
                )->db,
            where => [
                trader_id => $args->{trader_id},
                copier_id => $args->{copier_id},
            ],
        );

        for my $p (qw/assets trade_types/) {
            $args->{$p} ||= '*';
            $args->{$p} = [$args->{$p}] if ref $args->{$p} ne 'ARRAY';
        }

        for my $asset (@{$args->{assets}}) {
            for my $trade_type (@{$args->{trade_types}}) {
                BOM::Database::AutoGenerated::Rose::Copier->new(
                    broker          => 'CR',
                    trader_id       => $args->{trader_id},
                    copier_id       => $args->{copier_id},
                    min_trade_stake => $args->{min_trade_stake},
                    max_trade_stake => $args->{max_trade_stake},
                    trade_type      => $trade_type,
                    asset           => $asset,
                    trader_token    => $trader_token
                )->save;
            }
        }
    }
    'copy start';
}

my $i = 1;
subscribe({
    trader_id => 'CR0027',
    copier_id => 'CR0028'
});
subscribe({
    trader_id       => 'CR0027',
    copier_id       => 'CR0029',
    max_trade_stake => 100,
    trade_types     => 'CALL',
    assets          => 'frxUSDAUD'
});
my $dm = BOM::Database::DataMapper::Copier->new(
    broker_code => 'CR',
    operation   => 'write'
);
my $data_copiers_expected = [['CR0028', 'CR0027', $trader_token], ['CR0029', 'CR0027', $trader_token]];

my $data_traders_expected = [['CR0027', 'CR0029', $trader_token]];

is($dm->get_copiers_count({trader_id => 'CR0027'}), 2, 'check copiers count');
is_deeply($dm->get_copiers_tokens_all({trader_id => 'CR0027'}), $data_copiers_expected, 'expected data for copiers');

is($dm->get_traders({copier_id => 'CR0028'})->[0], 'CR0027', 'check trader');
is($dm->get_traders({copier_id => 'CR0029'})->[0], 'CR0027', 'check trader');
is_deeply($dm->get_traders_tokens_all({copier_id => 'CR0029'}), $data_traders_expected, 'expected data for traders');

is(
    scalar @{
        $dm->get_trade_copiers({
                trader_id  => 'CR0027',
                trade_type => 'CALL',
                asset      => 'frxUSDAUD',
                price      => 10
            })
    },
    2,
    'got all copiers'
);
is(
    scalar @{
        $dm->get_trade_copiers({
                trader_id  => 'CR0027',
                trade_type => 'PUT',
                asset      => 'frxUSDAUD',
                price      => 10
            })
    },
    1,
    'copiers filtered by trade type'
);
is(
    scalar @{
        $dm->get_trade_copiers({
                trader_id  => 'CR0027',
                trade_type => 'CALL',
                asset      => 'frxUSDJPY',
                price      => 10
            })
    },
    1,
    'copiers filtered by asset'
);
is(
    scalar @{
        $dm->get_trade_copiers({
                trader_id  => 'CR0027',
                trade_type => 'CALL',
                asset      => 'frxUSDAUD',
                price      => 1000
            })
    },
    1,
    'copiers filtered by stake'
);

$token_db->remove_by_token($trader_token, 'CR0027');
# For extra certainty, create a new trader token; it should not be used by the copiers
$token_db->create_token('CR0027', 'token2', ['read', 'trade', 'payments', 'admin']);

is($dm->get_copiers_count({trader_id => 'CR0027'}), 0, 'copier count is zero after removing trader token');

is(
    scalar @{
        $dm->get_trade_copiers({
                trader_id  => 'CR0027',
                trade_type => 'CALL',
                asset      => 'frxUSDAUD',
                price      => 10
            })
    },
    0,
    'no copiers returned after removing trader token'
);

is(scalar @{$dm->get_traders({copier_id => 'CR0028'})}, 0, 'CR0028 has no trader after removing trader token');
is(scalar @{$dm->get_traders({copier_id => 'CR0029'})}, 0, 'CR0029 has no trader after removing trader token');

# legacy case: betonmarkets.copiers.trader_token did not exist before, so it will be NULL for old copiers
$dm->db->dbic->run(fixup => sub { $_->do("UPDATE betonmarkets.copiers SET trader_token=NULL WHERE trader_id='CR0027'") });

is(
    scalar @{
        $dm->get_trade_copiers({
                trader_id  => 'CR0027',
                trade_type => 'CALL',
                asset      => 'frxUSDAUD',
                price      => 10
            })
    },
    2,
    'legacy case - copiers returned with null trader_token in copiers table'
);

subtest delete_copiers => sub {

    $dm->db->dbic->run(
        fixup => sub {
            $_->do(
                "INSERT INTO betonmarkets.copiers (trader_id, copier_id, trader_token) VALUES 
            ('CR0030', 'CR0032', NULL),
            ('CR0031','CR0032','asd'),
            ('CR0029', 'CR0032', NULL);"
            );
        });
    $dm->delete_copiers({
        trader_id => 'CR0030',
        copier_id => 'CR0032',
        token     => undef
    });

    $data_traders_expected = [['CR0031', 'CR0032', 'asd'], ['CR0029', 'CR0032', undef]];

    is_deeply($dm->get_traders_tokens_all({copier_id => 'CR0032'}), $data_traders_expected, 'expected data for copiers after delete with NULL token');

    $dm->delete_copiers({
        trader_id => 'CR0031',
        copier_id => 'CR0032',
        token     => 'asd'
    });

    $data_traders_expected = [['CR0029', 'CR0032', undef]];
    is_deeply($dm->get_traders_tokens_all({copier_id => 'CR0032'}),
        $data_traders_expected, 'expected data for copiers after delete with NON NULL token');
};

done_testing();
1;
