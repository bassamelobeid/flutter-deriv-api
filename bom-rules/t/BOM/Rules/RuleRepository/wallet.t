use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;

my $rule_name = 'wallet.client_type_is_not_binary';
subtest $rule_name => sub {

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_cr->set_default_account('USD');

    my $user = BOM::User->create(
        email    => 'wallet1@test.deriv',
        password => 'qwe1231Q@!',
    );
    $user->add_client($client_cr);

    my %args        = (loginid => $client_cr->loginid);
    my $rule_engine = BOM::Rules::Engine->new(
        client => $client_cr,
        user   => $client_cr->user
    );

    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'ClientAccountTypeIsBinary',
        rule       => $rule_name
        },
        'Client account type is binary';

    my $wallet = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CRW'});
    $wallet->account_type('doughflow');
    $wallet->set_default_account('USD');
    $wallet->save;
    $user->add_client($wallet);
    %args        = (loginid => $wallet->loginid);
    $rule_engine = BOM::Rules::Engine->new(
        client => $wallet,
        user   => $wallet->user
    );
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Client account type is not binary';
};

$rule_name = 'wallet.no_duplicate_trading_account';
subtest $rule_name => sub {

    my $user = BOM::User->create(
        email    => 'wallet2@test.deriv',
        password => 'x',
    );

    my $df_crw     = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CRW', account_type => 'doughflow'});
    my $crypto_crw = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CRW', account_type => 'crypto'});
    my $df_cr      = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR',  account_type => 'standard'});
    $user->add_client($_) for $df_crw, $crypto_crw;
    $user->add_client($df_cr, $df_crw->loginid);

    my $rule_engine = BOM::Rules::Engine->new(
        client => $df_crw,
        user   => $user,
    );

    my %args = (
        wallet_loginid => $df_crw->loginid,
        loginid        => $df_crw->loginid
    );
    lives_ok { $rule_engine->apply_rules($rule_name, %args, account_type => 'mt5') } 'Pass if account type is not standard';

    is_deeply(
        exception { $rule_engine->apply_rules($rule_name, %args, account_type => 'standard') },
        {
            error_code => 'DuplicateTradingAccount',
            rule       => $rule_name
        },
        'fails if account type is standard'
    );

    $df_cr->status->set('disabled', 'test', 'test');
    lives_ok { $rule_engine->apply_rules($rule_name, %args, account_type => 'standard') } 'Pass if existing trading account is disabled';

    $df_cr->status->clear_disabled;
    $df_cr->status->set('duplicate_account', 'test', 'test');
    lives_ok { $rule_engine->apply_rules($rule_name, %args, account_type => 'standard') }
    'Pass if existing trading account has duplicate_account status';

    $df_cr->status->clear_duplicate_account;
    is_deeply(
        exception { $rule_engine->apply_rules($rule_name, %args, account_type => 'standard') },
        {
            error_code => 'DuplicateTradingAccount',
            rule       => $rule_name
        },
        'fails after status is removed'
    );

    $rule_engine = BOM::Rules::Engine->new(
        client => $crypto_crw,
        user   => $user,
    );

    %args = (
        loginid        => $crypto_crw->loginid,
        wallet_loginid => $crypto_crw->loginid,
        account_type   => 'standard'
    );
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Other wallet passes';
};

done_testing();
