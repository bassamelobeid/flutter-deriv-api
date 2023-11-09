use strict;
use warnings;
use Test::More;
use Test::Deep;
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Helper::ExchangeRates;
use BOM::User;

BOM::Test::Helper::ExchangeRates::populate_exchange_rates({BTC => 25000});
my $redis = BOM::Config::Redis::redis_replicated_write();

my $user = BOM::User->create(
    email    => 'user@test.com',
    password => 'test',
);

my %args = (
    email                    => $user->email,
    salutation               => 'x',
    last_name                => 'x',
    first_name               => 'x',
    date_of_birth            => '1990-01-01',
    citizen                  => 'id',
    residence                => 'id',
    address_line_1           => 'x',
    address_line_2           => 'x',
    address_city             => 'x',
    address_state            => 'x',
    address_postcode         => 'x',
    phone                    => '123',
    client_password          => '',
    secret_question          => '',
    account_opening_reason   => 'Speculative',
    non_pep_declaration_time => '2023-01-01',
);

my %accs;
$accs{vrtc_binary} = $user->create_client(
    %args,
    broker_code  => 'VRTC',
    account_type => 'binary',
    currency     => 'USD'
);
$accs{cr_binary} = $user->create_client(
    %args,
    broker_code  => 'CR',
    account_type => 'binary',
    currency     => 'USD'
);
$accs{cr_btc} = $user->create_client(
    %args,
    broker_code  => 'CR',
    account_type => 'binary',
    currency     => 'BTC'
);
$user->add_loginid('MTR001', 'mt5',     'real', 'USD');
$user->add_loginid('DXR001', 'dxtrade', 'real', 'USD');
$user->add_loginid('EZR001', 'derivez', 'real', 'USD');
$user->add_loginid('CTR001', 'ctrader', 'real', 'USD');

$accs{vrw} = $user->create_wallet(
    %args,
    broker_code  => 'VRW',
    account_type => 'virtual',
    currency     => 'USD'
);
$accs{vrw_standard} = $user->create_client(
    %args,
    broker_code    => 'VRTC',
    account_type   => 'standard',
    currency       => 'USD',
    wallet_loginid => $accs{vrw}->loginid
);
$user->add_loginid('MTD002', 'mt5',     'demo', 'USD');
$user->add_loginid('DXD002', 'dxtrade', 'demo', 'USD');
$user->add_loginid('EZD002', 'derivez', 'demo', 'USD');
$user->add_loginid('CTD002', 'ctrader', 'demo', 'USD');

$accs{doughflow} = $user->create_wallet(
    %args,
    broker_code  => 'CRW',
    account_type => 'doughflow',
    currency     => 'USD'
);
$accs{doughflow_standard} = $user->create_client(
    %args,
    broker_code    => 'CR',
    account_type   => 'standard',
    currency       => 'USD',
    wallet_loginid => $accs{doughflow}->loginid
);
$user->add_loginid('MTR002', 'mt5',     'real', 'USD', undef, $accs{doughflow}->loginid);
$user->add_loginid('DXR002', 'dxtrade', 'real', 'USD', undef, $accs{doughflow}->loginid);
$user->add_loginid('EZR002', 'derivez', 'real', 'USD', undef, $accs{doughflow}->loginid);
$user->add_loginid('CTR002', 'ctrader', 'real', 'USD', undef, $accs{doughflow}->loginid);

$accs{crypto} = $user->create_wallet(
    %args,
    broker_code  => 'CRW',
    account_type => 'crypto',
    currency     => 'BTC'
);
$user->add_loginid('MTR003', 'mt5', 'real', 'USD', undef, $accs{crypto}->loginid);

$accs{pa} = $user->create_wallet(
    %args,
    broker_code  => 'CRW',
    account_type => 'paymentagent',
    currency     => 'USD'
);

subtest get_transfer_limit_type => sub {

    subtest 'legacy' => sub {

        cmp_deeply(
            $user->get_transfer_limit_type(
                client_from => $accs{cr_binary},
                client_to   => $accs{cr_btc}
            ),
            {
                identifier  => $user->id,
                type        => 'internal',
                config_name => 'between_accounts',

            },
            'legacy fiat -> legacy crypto'
        );

        cmp_deeply(
            $user->get_transfer_limit_type(
                client_from => $accs{cr_binary},
                loginid_to  => 'MTR001'
            ),
            {
                identifier  => $user->id,
                type        => 'MT5',
                config_name => 'MT5',

            },
            'legacy fiat -> mt5'
        );

        cmp_deeply(
            $user->get_transfer_limit_type(
                loginid_from => 'DXR001',
                client_to    => $accs{cr_binary}
            ),
            {
                identifier  => $user->id,
                type        => 'dxtrade',
                config_name => 'dxtrade',

            },
            'dxtrade -> legacy fiat'
        );

        cmp_deeply(
            $user->get_transfer_limit_type(
                client_from => $accs{cr_btc},
                loginid_to  => 'EZR001'
            ),
            {
                identifier  => $user->id,
                type        => 'derivez',
                config_name => 'derivez',

            },
            'legacy btc -> derivez'
        );

        cmp_deeply(
            $user->get_transfer_limit_type(
                loginid_from => 'CTR001',
                client_to    => $accs{cr_btc}
            ),
            {
                identifier  => $user->id,
                type        => 'ctrader',
                config_name => 'ctrader',

            },
            'ctrader -> legacy btc'
        );
    };

    subtest 'virtual wallet' => sub {

        cmp_deeply(
            $user->get_transfer_limit_type(
                client_from => $accs{vrw},
                client_to   => $accs{vrw_standard}
            ),
            {
                identifier  => $user->id,
                type        => 'virtual',
                config_name => 'virtual',

            },
            'virtual wallet -> virtual trading'
        );

        cmp_deeply(
            $user->get_transfer_limit_type(
                client_from => $accs{vrw},
                loginid_to  => 'MTD002'
            ),
            {
                identifier  => $user->id,
                type        => 'virtual',
                config_name => 'virtual',

            },
            'virtual wallet -> mt5'
        );

        cmp_deeply(
            $user->get_transfer_limit_type(
                loginid_from => 'DXD002',
                client_to    => $accs{vrw}
            ),
            {
                identifier  => $user->id,
                type        => 'virtual',
                config_name => 'virtual',

            },
            'dxtrade -> virtual wallet'
        );
    };

    subtest 'real wallets' => sub {

        cmp_deeply(
            $user->get_transfer_limit_type(
                client_from => $accs{doughflow},
                client_to   => $accs{crypto}
            ),
            {
                identifier  => $user->id,
                type        => 'internal',
                config_name => 'between_accounts',

            },
            'doughflow wallet -> crypto wallet'
        );

        cmp_deeply(
            $user->get_transfer_limit_type(
                client_from => $accs{doughflow},
                client_to   => $accs{pa}
            ),
            {
                identifier  => $user->id,
                type        => 'wallet',
                config_name => 'between_wallets',

            },
            'doughflow wallet -> pa wallet'
        );

        cmp_deeply(
            $user->get_transfer_limit_type(
                client_from => $accs{pa},
                client_to   => $accs{crypto}
            ),
            {
                identifier  => $user->id,
                type        => 'wallet',
                config_name => 'between_wallets',

            },
            'pa wallet -> crypto wallet'
        );

        cmp_deeply(
            $user->get_transfer_limit_type(
                client_from => $accs{doughflow},
                client_to   => $accs{doughflow_standard}
            ),
            {
                identifier  => $accs{doughflow}->loginid,
                type        => 'dtrade',
                config_name => 'dtrade',

            },
            'doughflow wallet -> standard'
        );

        cmp_deeply(
            $user->get_transfer_limit_type(
                client_from => $accs{doughflow},
                loginid_to  => 'MTR002'
            ),
            {
                identifier  => $accs{doughflow}->loginid,
                type        => 'MT5',
                config_name => 'MT5',

            },
            'doughflow wallet -> mt5'
        );

        cmp_deeply(
            $user->get_transfer_limit_type(
                client_from => $accs{doughflow},
                loginid_to  => 'DXR002'
            ),
            {
                identifier  => $accs{doughflow}->loginid,
                type        => 'dxtrade',
                config_name => 'dxtrade',

            },
            'doughflow wallet -> dxtrade'
        );

        cmp_deeply(
            $user->get_transfer_limit_type(
                loginid_from => 'EZR002',
                client_to    => $accs{doughflow}
            ),
            {
                identifier  => $accs{doughflow}->loginid,
                type        => 'derivez',
                config_name => 'derivez',

            },
            'derivez -> doughflow wallet'
        );

        cmp_deeply(
            $user->get_transfer_limit_type(
                loginid_from => 'CTR002',
                client_to    => $accs{doughflow}
            ),
            {
                identifier  => $accs{doughflow}->loginid,
                type        => 'ctrader',
                config_name => 'ctrader',

            },
            'ctrader -> doughflow wallet'
        );

        cmp_deeply(
            $user->get_transfer_limit_type(
                client_from => $accs{crypto},
                loginid_to  => 'MTR003'
            ),
            {
                identifier  => $accs{crypto}->loginid,
                type        => 'MT5',
                config_name => 'MT5',

            },
            'crypto wallet -> mt5'
        );
    };
};

my $expected;
my %initial = (
    count  => 0,
    amount => 0
);
$expected->{internal}{user}     = {%initial};
$expected->{MT5}{user}          = {%initial};
$expected->{dxtrade}{user}      = {%initial};
$expected->{derivez}{user}      = {%initial};
$expected->{ctrader}{user}      = {%initial};
$expected->{virtual}{user}      = {%initial};
$expected->{wallet}{user}       = {%initial};
$expected->{dtrade}{doughflow}  = {%initial};
$expected->{MT5}{doughflow}     = {%initial};
$expected->{dxtrade}{doughflow} = {%initial};
$expected->{derivez}{doughflow} = {%initial};
$expected->{ctrader}{doughflow} = {%initial};
$expected->{MT5}{crypto}        = {%initial};
$expected->{dxtrade}{crypto}    = {%initial};
$expected->{derivez}{crypto}    = {%initial};
$expected->{ctrader}{crypto}    = {%initial};

sub check_limits {
    subtest shift() => sub {
        for my $type (sort keys %$expected) {
            for my $id_type (sort keys $expected->{$type}->%*) {
                my $identifier = $id_type eq 'user' ? $user->id : $accs{$id_type}->loginid;
                my $vals       = $expected->{$type}{$id_type};
                is $user->daily_transfer_count(
                    type       => $type,
                    identifier => $identifier
                    ),
                    $vals->{count}, "$type $id_type count";
                is $user->daily_transfer_amount(
                    type       => $type,
                    identifier => $identifier
                    ),
                    $vals->{amount}, "$type $id_type amount";
            }
        }
    }
}

subtest 'record and get limits' => sub {

    check_limits('initial values');

    $user->daily_transfer_incr(
        client_from     => $accs{cr_binary},
        client_to       => $accs{cr_btc},
        amount          => 1.23,
        amount_currency => 'USD'
    );
    $expected->{internal}{user}{count}++;
    $expected->{internal}{user}{amount} += 1.23;
    check_limits('legacy transfer');

    $user->daily_transfer_incr(
        client_from     => $accs{cr_btc},
        client_to       => $accs{cr_binary},
        amount          => -0.001,
        amount_currency => 'BTC'
    );
    $expected->{internal}{user}{count}++;
    $expected->{internal}{user}{amount} += (0.001 * 25000);
    check_limits('legacy crypto transfer');

    $user->daily_transfer_incr(
        client_from     => $accs{cr_binary},
        loginid_to      => 'MTR001',
        amount          => 0.99,
        amount_currency => 'USD'
    );
    $expected->{MT5}{user}{count}++;
    $expected->{MT5}{user}{amount} += 0.99;
    check_limits('legacy MT5 transfer');

    $user->daily_transfer_incr(
        client_from     => $accs{vrw},
        client_to       => $accs{vrw_standard},
        amount          => 1.01,
        amount_currency => 'USD'
    );
    $expected->{virtual}{user}{count}++;
    $expected->{virtual}{user}{amount} += 1.01;
    check_limits('vrw -> standard');

    $user->daily_transfer_incr(
        client_from     => $accs{vrw},
        loginid_to      => 'MTD002',
        amount          => 1.02,
        amount_currency => 'USD'
    );
    $expected->{virtual}{user}{count}++;
    $expected->{virtual}{user}{amount} += 1.02;
    check_limits('vrw -> mt5');

    $user->daily_transfer_incr(
        client_from     => $accs{doughflow},
        client_to       => $accs{doughflow_standard},
        amount          => 1.03,
        amount_currency => 'USD'
    );
    $expected->{dtrade}{doughflow}{count}++;
    $expected->{dtrade}{doughflow}{amount} += 1.03;
    check_limits('doughflow -> standard');

    $user->daily_transfer_incr(
        loginid_from    => 'DXR002',
        client_to       => $accs{doughflow},
        amount          => 1.04,
        amount_currency => 'USD'
    );
    $expected->{dxtrade}{doughflow}{count}++;
    $expected->{dxtrade}{doughflow}{amount} += 1.04;
    check_limits('dxtrade -> doughflow');

    $user->daily_transfer_incr(
        client_from     => $accs{crypto},
        loginid_to      => 'MTR003',
        amount          => 0.002,
        amount_currency => 'BTC'
    );
    $expected->{MT5}{crypto}{count}++;
    $expected->{MT5}{crypto}{amount} += (0.002 * 25000);
    check_limits('crypto -> mt5');
};

done_testing;
