use strict;
use warnings;
use Test::More;
use Test::Deep;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Platform::Account::Virtual;
use BOM::Platform::Account::Real::default;
use BOM::Database::Model::OAuth;
use BOM::Config::Runtime;
use Data::Dumper;
use await;
use Guard;

my $t = build_wsapi_test();

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

my %init_config_values = (
    'system.suspend.wallets' => $app_config->system->suspend->wallets,
);

scope_guard {
    for my $key (keys %init_config_values) {
        $app_config->set({$key => $init_config_values{$key}});
    }
};

$app_config->set({'system.suspend.wallets' => 0});

subtest 'Wallet migration' => sub {
    # create VR acc
    my ($vr_client, $user) = create_vr_account({
        email           => 'test@example.com',
        client_password => 'abc123',
        residence       => 'ru',
    });

    # authorize
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    subtest 'Start wallet migration' => sub {
        my $res = $t->await::wallet_migration({wallet_migration => 'state'});

        is($res->{wallet_migration}{state}, 'ineligible', 'Got correct state');

        SKIP: {
            skip "Since wallets are not enabled for any country at the moment, we skip this test";
            my $usd_client = add_usd_account(user => $user);

            $res = $t->await::wallet_migration({wallet_migration => 'state'});

            is($res->{wallet_migration}{state}, 'eligible', 'Got correct state');

            cmp_deeply(
                $res->{wallet_migration}{account_list},
                bag({
                        account_type          => 'virtual',
                        currency              => 'USD',
                        landing_company_short => 'virtual',
                        platform              => 'dwallet',
                        account_category      => 'wallet',
                        link_accounts         => [{
                                loginid          => $vr_client->loginid,
                                account_category => 'trading',
                                platform         => 'dtrade',
                                account_type     => 'standard',
                            }
                        ],
                    },
                    {
                        account_type          => 'doughflow',
                        currency              => 'USD',
                        landing_company_short => 'svg',
                        platform              => 'dwallet',
                        account_category      => 'wallet',
                        link_accounts         => [{
                                loginid          => $usd_client->loginid,
                                account_category => 'trading',
                                platform         => 'dtrade',
                                account_type     => 'standard',
                            }
                        ],
                    }
                ),
                'Got correct account list'
            );

            $res = $t->await::wallet_migration({wallet_migration => 'start'});

            is($res->{wallet_migration}{state}, 'in_progress', 'Got correct state');
        }
    };
};

sub create_vr_account {
    my $args = shift;
    my $acc  = BOM::Platform::Account::Virtual::create_account({
            details => {
                email           => $args->{email},
                client_password => $args->{client_password},
                residence       => $args->{residence},
                account_type    => 'binary',
            },
            email_verified => 1
        });

    return ($acc->{client}, $acc->{user});
}

sub add_usd_account {
    my %args = @_;

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        date_joined => '2023-01-01 23:59:59',
    });

    $client->set_default_account('USD');

    $args{user}->add_client($client);

    return $client;
}

$t->finish_ok;

done_testing;
