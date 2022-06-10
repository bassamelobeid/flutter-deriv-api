use Test::More;
use Test::MockModule;
use Test::Deep;

use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Client::AntiFraud;
use BOM::User::PaymentRecord;
use BOM::User;

use Digest::SHA qw/sha256_hex/;

my $antifraud;
my $btc_antifraud;

my $user = BOM::User->create(
    email    => 'test+antifraud@binary.com',
    password => 'password',
);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => 'test+antifraud@binary.com',
    binary_user_id => $user->id,
    residence      => 'za',
});

$client->set_default_account('USD');

my $btc_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => 'test+antifraud@binary.com',
    binary_user_id => $user->id,
    residence      => 'za',
});

$btc_client->set_default_account('BTC');

subtest 'instantiate' => sub {
    $antifraud = BOM::Platform::Client::AntiFraud->new(client => $client);
    isa_ok $antifraud, 'BOM::Platform::Client::AntiFraud';

    is $client->loginid, $antifraud->client->loginid, 'Expected client';

    $btc_antifraud = BOM::Platform::Client::AntiFraud->new(client => $btc_client);
    isa_ok $btc_antifraud, 'BOM::Platform::Client::AntiFraud';

    is $btc_client->loginid, $btc_antifraud->client->loginid, 'Expected client';
};

subtest 'df cumulative total by payment type' => sub {
    my $cumulative_total = {
        CreditCard => 0,
    };

    my $df_mock = Test::MockModule->new('BOM::Database::DataMapper::Payment::DoughFlow');
    $df_mock->mock(
        'payment_type_cumulative_total',
        sub {
            my (undef, $args) = @_;

            my $payment_type = $args->{payment_type};

            return $cumulative_total->{$payment_type};
        });

    # note this test is based on the default configuration
    # assume: za -> CreditCard -> limit: 500, days: 7

    ok !$antifraud->df_cumulative_total_by_payment_type('CreditCard'), 'Cumulative total has not been breached';

    $cumulative_total->{CreditCard} = 500;

    ok !$antifraud->df_cumulative_total_by_payment_type('DogPay'), 'Cumulative total has not been breached (diff payment type)';

    $cumulative_total->{DogPay} = 500;

    ok !$antifraud->df_cumulative_total_by_payment_type('DogPay'), 'The is no config for this payment type';

    $antifraud->client->residence('br');
    $antifraud->client->save();

    ok !$antifraud->df_cumulative_total_by_payment_type('CreditCard'), 'Cumulative total has not been breached (diff residence)';

    $antifraud->client->residence('za');
    $antifraud->client->save();

    ok $antifraud->df_cumulative_total_by_payment_type('CreditCard'), 'Cumulative total has been breached';

    subtest 'exchange rates' => sub {
        $cumulative_total->{CreditCard} = 1;

        populate_exchange_rates({BTC => 100});
        ok !$btc_antifraud->df_cumulative_total_by_payment_type('CreditCard'), 'Cumulative total has not been breached';

        populate_exchange_rates({BTC => 500});
        ok !$btc_antifraud->df_cumulative_total_by_payment_type('DogPay'), 'Cumulative total has not been breached (diff payment type)';

        $cumulative_total->{DogPay} = 100;
        ok !$btc_antifraud->df_cumulative_total_by_payment_type('DogPay'), 'There is no config for this payment type';

        $btc_antifraud->client->residence('br');
        $btc_antifraud->client->save();

        ok !$btc_antifraud->df_cumulative_total_by_payment_type('CreditCard'), 'Cumulative total has not been breached (diff residence)';

        $btc_antifraud->client->residence('za');
        $btc_antifraud->client->save();

        ok $btc_antifraud->df_cumulative_total_by_payment_type('CreditCard'), 'Cumulative total has been breached';
    };
};

subtest 'df total payments by identifier' => sub {
    my $conf_mock = Test::MockModule->new('BOM::Config::Payments::PaymentMethods');
    my $high_risk_settings;
    $conf_mock->mock(
        'high_risk',
        sub {
            return $high_risk_settings;
        });

    my $pr_mock = Test::MockModule->new('BOM::User::PaymentRecord');
    my $raw_payments;
    $pr_mock->mock(
        'get_raw_payments',
        sub {
            return $raw_payments;
        });

    my $cli_mock = Test::MockModule->new('BOM::User::Client');
    $cli_mock->mock(
        'payment_accounts_limit',
        sub {
            return $high_risk_settings->{limit} // 0;
        });

    subtest 'No payment type given' => sub {
        ok !$antifraud->df_total_payments_by_payment_type(), 'Cannot violate a non existant rule';
    };

    subtest 'No settings for type given' => sub {
        ok !$antifraud->df_total_payments_by_payment_type('huzzah'), 'Cannot violate a non existant rule';
    };

    subtest 'type exists' => sub {
        $high_risk_settings = {
            days  => 10,
            limit => 9,
        };

        $raw_payments = [
            'Test|Capy|Bara|0x01|1|USD',  'Test|Capy|Bara|0x01|1|EUR', 'Asdf|Capy|Bara|0x01|2|USD',  'Test|Asdf|Bara|0x01|3|USD',
            'Test|Capy|Asdf|0x01|5|USD',  'Test|Capy|Asdf|0x01|8|USD', 'Test|Capy|Bara|0x02|13|USD', 'Test|Capy|Bara|0x03|21|USD',
            'Test|Capy|Bara|0x01|34|USD', 'Test|Capy|Bara|0x01|55|USD',
        ];

        ok !$antifraud->df_total_payments_by_payment_type('Bara'), 'Limit not yet breached';

        $high_risk_settings = {
            days  => 10,
            limit => 8,
        };

        ok $antifraud->df_total_payments_by_payment_type('Bara'), 'Limit breached';

        $high_risk_settings = {
            days  => 10,
            limit => 3,
        };

        ok !$antifraud->df_total_payments_by_payment_type('Asdf'), 'Limit not breached';

        $high_risk_settings = {
            days  => 10,
            limit => 2,
        };

        ok $antifraud->df_total_payments_by_payment_type('Asdf'), 'Limit breached';

        ok $antifraud->df_total_payments_by_payment_type('Bara'), 'Limit breached';

        $high_risk_settings = {
            days  => 10,
            limit => 0,
        };

        ok !$antifraud->df_total_payments_by_payment_type('Bara'), 'Limit not breached (limit=0 is not checked)';
    };

    # todo: remove this test when the time comes

    subtest 'deprecated redis' => sub {
        add_legacy_payment(
            id      => 2000,
            user_id => $user->id,
            pt      => 'Bara',
        );

        $raw_payments = [];

        $high_risk_settings = {
            days  => 10,
            limit => 2,
        };

        ok !$antifraud->df_total_payments_by_payment_type('Bara'), 'Limit not breached';

        add_legacy_payment(
            id      => 2000,
            user_id => $user->id,
            pt      => 'Bara',
        );

        ok !$antifraud->df_total_payments_by_payment_type('Bara'), 'Limit not breached';

        add_legacy_payment(
            id      => 3000,
            user_id => $user->id,
            pt      => 'Bara',
        );

        ok $antifraud->df_total_payments_by_payment_type('Bara'), 'Limit breached';

        # they can work in tandem

        $high_risk_settings = {
            days  => 10,
            limit => 3,
        };

        ok !$antifraud->df_total_payments_by_payment_type('Bara'), 'Limit not breached';

        $raw_payments = ['Test|Capy|Bara|0x01|1|USD',];

        ok $antifraud->df_total_payments_by_payment_type('Bara'), 'Limit breached';
    };

    $pr_mock->unmock_all;
    $conf_mock->unmock_all;
    $cli_mock->unmock_all;
};

sub add_legacy_payment : method {
    my (%args) = @_;
    my $account_identifier = $args{id};

    return 0 unless $account_identifier;

    my $storage_key = BOM::User::PaymentRecord::_build_storage_key(
        user_id      => $args{user_id},
        payment_type => $args{pt});
    return 0 unless $storage_key;

    my $redis = BOM::User::PaymentRecord::_get_redis();
    $redis->multi;
    $redis->pfadd($storage_key, sha256_hex($account_identifier));
    # we set the expiry of the whole key
    # we extend expiry whenever the same key is updated
    $redis->expire($storage_key, 90);
    $redis->exec;

    return 1;
}

done_testing();
