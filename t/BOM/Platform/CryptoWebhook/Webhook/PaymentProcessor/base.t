use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;

use Syntax::Keyword::Try;

use BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Base;
use BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Coinspaid;

subtest 'config' => sub {
    my $mocked_bom_config = Test::MockModule->new('BOM::Config');

    #case when config not found in bom config
    my $config = {};

    $mocked_bom_config->mock(
        third_party => sub {
            return $config;
        },
    );

    my $base_instance = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Base->new;

    try {
        $base_instance->config();
        is 1, 0, 'should not reach here';
    } catch ($e) {
        like $e, qr/missing crypto third party payment processors api tokens config/, 'should die when config not found in bom-config';
    }

    #case when config found in bom-config
    $config = {
        crypto_webhook => {
            coinspaid => {
                secret_key => "test_token",
            },
        },
    };

    is_deeply $base_instance->config(), {%{$config->{crypto_webhook}}}, 'Correct config fetched';

    $mocked_bom_config->unmock_all();
};

subtest 'processor_name' => sub {
    my $base_instance = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Base->new;
    is $base_instance->processor_name, undef, 'Correct payment processor, base has no processor name.';
};

subtest 'signature_keys' => sub {
    my $mocked_base = Test::MockModule->new('BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Base');

    my $base_instance = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Base->new;
    #case when signature_keys not found in self->config
    my $config = {

    };

    $mocked_base->mock(
        config => sub {
            return $config;
        },
    );

    try {
        $base_instance->signature_keys();
        is 1, 0, 'should not reach here';
    } catch ($e) {
        like $e, qr/missing signature keys\/token for /, 'should die when signature_keys not found in config';
    }

    #case when signature_keys found in self->config
    $config = {
        '' => {
            secret_key => "test_token",
        },
    };
    is_deeply $base_instance->signature_keys(), {%{$config->{''}}}, 'Correct signature_keys fetched';

    $mocked_base->unmock_all();
};

subtest 'Required methods, calling these should throw error' => sub {
    my $base_instance = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Base->new;

    my $required_methods = ['validate_signature', 'transform_status', 'transform_currency', 'process_deposit', 'process_withdrawal',];

    for my $method ($required_methods->@*) {
        try {
            $base_instance->$method->();
            is 1, 0, 'should not reach here';
        } catch ($e) {
            like $e, qr/Not implemented/, 'base->' . $method . ' should die, must be called from derived class';
        }
    }
};

subtest 'emit_deposit_event' => sub {
    my $base_instance = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Base->new;

    #cases when transaction passed missing fields
    my $cases = [{
            payload => undef,
            error   => 'missing parameter trace_id'
        },
        {
            payload => {trace_id => 123},
            error   => 'missing parameter status'
        },
        {
            payload => {
                trace_id => 123,
                status   => 'pending',
            },
            error => 'missing parameter address'
        },
        {
            payload => {
                trace_id => 123,
                status   => 'pending',
                address  => 'address1',
            },
            error => 'missing parameter amount'
        },
        {
            payload => {
                trace_id => 123,
                status   => 'pending',
                address  => 'address1',
                amount   => 0,
            },
            error => 'missing parameter currency'
        },
        {
            payload => {
                trace_id => 123,
                status   => 'pending',
                address  => 'address1',
                amount   => 0,
                currency => 'tUSDT',
            },
            error => 'missing parameter hash'
        },
        {
            payload => {
                trace_id => 123,
                status   => 'pending',
                address  => 'address1',
                amount   => 0,
                currency => 'tUSDT',
                hash     => 'txn_hash',
            },
            error => 'missing parameter transaction_fee'
        },
        {
            payload => {
                trace_id         => 123,
                status           => 'pending',
                address          => 'address1',
                amount           => 0,
                currency         => 'tUSDT',
                hash             => 'txn_hash',
                amount_minus_fee => 0,
            },
            error => 'missing parameter transaction_fee'
        }];

    for my $case ($cases->@*) {
        try {
            $base_instance->emit_deposit_event($case->{payload});
            is 1, 0, 'should not reach here';
        } catch ($e) {
            like $e, qr/$case->{error}/, 'Correct error: ' . ($case->{error} // '');
        }
    }

    #case when deposit event emission fails
    my $mocked_base   = Test::MockModule->new('BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Base');
    my $event_success = 'failed';
    $mocked_base->mock(
        stats_inc => sub {
            my ($metric_name, $params) = @_;
            my $tags = $params->{tags};

            my @expected_tags = ("currency:tUSDT", "status:$event_success", "processor:");

            is $metric_name, BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Base::DD_METRIC_PREFIX . 'deposit',
                "Correct DD metric name for deposit case";
            is_deeply $tags, \@expected_tags, 'Correct tags for the DD metric';
        });

    my $mocked_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
    $mocked_emitter->mock(
        emit => sub {
            die "Event emission failed" unless $event_success eq 'success';
            return 1;
        },
    );

    my $payload = {
        trace_id         => 123,
        status           => 'pending',
        address          => 'address1',
        amount           => 0,
        currency         => 'tUSDT',
        hash             => 'txn_hash',
        transaction_fee  => 0.01,
        amount_minus_fee => 0,
    };

    is $base_instance->emit_deposit_event($payload), 0, 'Correct result when deposit event emission failed.';

    #case when deposit event emission success
    $event_success = 'success';
    is $base_instance->emit_deposit_event($payload), 1, 'Correct result when deposit event emission success.';

    $mocked_base->unmock_all();
    $mocked_emitter->unmock_all();
};

subtest 'emit_withdrawal_event' => sub {
    my $base_instance = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Base->new;

    #cases when transaction passed missing fields
    my $cases = [{
            payload => undef,
            error   => 'missing parameter trace_id'
        },
        {
            payload => {trace_id => 123},
            error   => 'missing parameter reference_id'
        },
        {
            payload => {
                trace_id     => 123,
                reference_id => 3456,
            },
            error => 'missing parameter status'
        },
        {
            payload => {
                trace_id     => 123,
                reference_id => 3456,
                status       => 'pending',
            },
            error => 'missing parameter address'
        },
        {
            payload => {
                trace_id     => 123,
                reference_id => 3456,
                status       => 'pending',
                address      => 'address1',
            },
            error => 'missing parameter amount'
        },
        {
            payload => {
                trace_id     => 123,
                reference_id => 3456,
                status       => 'pending',
                address      => 'address1',
                amount       => 0,
            },
            error => 'missing parameter currency'
        },
        {
            payload => {
                trace_id     => 123,
                reference_id => 3456,
                status       => 'pending',
                address      => 'address1',
                amount       => 0,
                currency     => 'tUSDT',
            },
            error => 'missing parameter hash'
        },
        {
            payload => {
                trace_id     => 123,
                reference_id => 3456,
                status       => 'pending',
                address      => 'address1',
                amount       => 0,
                currency     => 'tUSDT',
                hash         => 'txn_hash',
            },
            error => 'missing parameter transaction_fee'
        }];

    for my $case ($cases->@*) {
        try {
            $base_instance->emit_withdrawal_event($case->{payload});
            is 1, 0, 'should not reach here';
        } catch ($e) {
            like $e, qr/$case->{error}/, 'Correct error: ' . ($case->{error} // '');
        }
    }

    #case when withdrawal event emission fails
    my $mocked_base   = Test::MockModule->new('BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Base');
    my $event_success = 'failed';
    $mocked_base->mock(
        stats_inc => sub {
            my ($metric_name, $params) = @_;
            my $tags = $params->{tags};

            my @expected_tags = ("currency:tUSDT", "status:$event_success", "processor:");

            is $metric_name, BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Base::DD_METRIC_PREFIX . 'withdrawal',
                "Correct DD metric name for withdrawal case";
            is_deeply $tags, \@expected_tags, 'Correct tags for the DD metric';
        });

    my $mocked_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
    $mocked_emitter->mock(
        emit => sub {
            die "Event emission failed" unless $event_success eq 'success';
            return 1;
        },
    );

    my $payload = {
        trace_id        => 123,
        reference_id    => 3456,
        status          => 'pending',
        address         => 'address1',
        amount          => 0,
        currency        => 'tUSDT',
        hash            => 'txn_hash',
        transaction_fee => 0.01,
    };

    is $base_instance->emit_withdrawal_event($payload), 0, 'Correct result when withdrawal event emission failed.';

    #case when deposit event emission success
    $event_success = 'success';
    is $base_instance->emit_withdrawal_event($payload), 1, 'Correct result when deposit event emission success.';

    $mocked_base->unmock_all();
    $mocked_emitter->unmock_all();
};

done_testing;
