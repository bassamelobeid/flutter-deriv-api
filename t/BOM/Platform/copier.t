use strict;
use warnings;
use Test::More;
use BOM::Platform::Copier;
use Test::Exception;
use Test::Warn;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Copier;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

lives_ok {
    BOM::Platform::Copier->update_or_create({
        trader_id       => 'CR0027',
        copier_id       => 'CR0028',
        broker          => 'CR',
        min_trade_stake => 10,
        max_trade_stake => 100,
        assets          => [],
        trade_types     => ['CALL'],
    });
}
'create copier #1';

lives_ok {
    BOM::Platform::Copier->update_or_create({
        trader_id => 'CR0027',
        copier_id => 'CR0029',
        broker    => 'CR',
    });
}
'create copier #2';

my $dm = BOM::Database::DataMapper::Copier->new(
    broker_code => 'CR',
    operation   => 'replica'
);

is($dm->get_copiers_count({trader_id => 'CR0027'}), 2, 'check copiers count');
is($dm->get_traders({copier_id => 'CR0028'})->[0], 'CR0027', 'check trader');
is($dm->get_traders({copier_id => 'CR0029'})->[0], 'CR0027', 'check trader');

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
    'got filtered copiers'
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
    'got filtered copiers'
);

subtest duplicate_entries => sub {
    BOM::Platform::Copier->update_or_create({
        trader_id       => 'CR0027',
        copier_id       => 'CR0028',
        broker          => 'CR',
        min_trade_stake => 10,
        max_trade_stake => 100,
        assets          => [],
        trade_types     => ['CALL', 'CALL'],
    });
    #we don't use the get_trader_* calls here because they mask the issue.
    my $clientdb = BOM::Database::ClientDB->new({broker_code => 'CR'});
    my $dbic     = $clientdb->db->dbic;
    my $result   = $dbic->run(
        fixup => sub {
            $_->selectall_arrayref("SELECT * FROM betonmarkets.copiers WHERE trader_id = 'CR0027' AND copier_id = 'CR0028' AND trade_type = 'CALL'");
        });
    is(scalar @$result, 1, 'Duplicate Trade types do not create duplicate entries');
};
done_testing;
