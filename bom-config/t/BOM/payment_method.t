use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;

use BOM::Config::Payments::PaymentMethods;
use BOM::Config::Runtime;
use JSON::MaybeUTF8;

my $app_config_mock   = Test::MockModule->new(ref(BOM::Config::Runtime->instance->app_config));
my $app_config_update = 0;
$app_config_mock->mock(
    'check_for_update',
    sub {
        $app_config_update = 1;
        return $app_config_mock->original('check_for_update')->(@_);
    });

my $payment_method_config = BOM::Config::Payments::PaymentMethods->new;
isa_ok $payment_method_config, 'BOM::Config::Payments::PaymentMethods', 'expected instance created';
ok $app_config_update, 'App config update hit';

my $default_config = {
    CreditCard => {
        limit    => 5,
        days     => 90,
        siblings => []}};

subtest 'high risk' => sub {
    my $settings = $payment_method_config->high_risk('CreditCard');

    cmp_deeply $settings, $default_config->{CreditCard}, 'Expected settings for CreditCard';

    is $payment_method_config->high_risk('Skrill'), undef, 'Skrill is not a high risk pm';

    $default_config->{Skrill} = {
        limit    => 1,
        days     => 30,
        siblings => ['Skrill1', 'Skrill2']};

    BOM::Config::Runtime->instance->app_config->payments->payment_methods->high_risk(JSON::MaybeUTF8::encode_json_utf8($default_config));

    # flush cache
    $payment_method_config->clear_high_risk_settings();

    $settings = $payment_method_config->high_risk('Skrill');

    cmp_deeply $settings, $default_config->{Skrill}, 'Expected settings for Skrill';

    $settings = $payment_method_config->high_risk('Skrill1');

    cmp_deeply $settings,
        +{
        group => 'Skrill',
        $default_config->{Skrill}->%*
        },
        'Expected settings for Skrill1';

    $settings = $payment_method_config->high_risk('Skrill2');

    cmp_deeply $settings,
        +{
        group => 'Skrill',
        $default_config->{Skrill}->%*
        },
        'Expected settings for Skrill2';

    subtest 'group' => sub {
        is $payment_method_config->high_risk_group('CreditCard'), 'CreditCard', 'expected group for CreditCard';
        is $payment_method_config->high_risk_group('Skrill'),     'Skrill',     'expected group for Skrill';
        is $payment_method_config->high_risk_group('Skrill1'),    'Skrill',     'expected group for Skrill1';
        is $payment_method_config->high_risk_group('Skrill2'),    'Skrill',     'expected group for Skrill2';
        is $payment_method_config->high_risk_group('void'),       undef,        'expected group for void';
    };
};

$app_config_mock->unmock_all;

done_testing();
