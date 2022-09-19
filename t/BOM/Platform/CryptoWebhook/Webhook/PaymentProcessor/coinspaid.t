use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;

use Digest::SHA qw(hmac_sha512_hex);
use Syntax::Keyword::Try;

use BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor;
use BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Coinspaid;

subtest 'processor_name' => sub {
    my $coinspaid = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor->new(processor_name => 'Coinspaid');
    is $coinspaid->processor_name, 'Coinspaid', 'Correct payment processor';
};

subtest 'validate_signature' => sub {
    my $json_body = {
        id   => 123,
        type => 'deposit',
        #.....
    };
    my $api_secret       = "some_dummy_signature";
    my $mocked_coinspaid = Test::MockModule->new('BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Coinspaid');

    my $coinspaid = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor->new(processor_name => 'Coinspaid');

    #case when passed signature is empty
    my $provided_signature = undef;
    is $coinspaid->validate_signature($provided_signature, $json_body), 0, 'Correct result when wrong signature is passed';

    #case api token not found in config
    $mocked_coinspaid->mock(
        signature_keys => sub {
            return {};
        },
    );

    try {
        $provided_signature = hmac_sha512_hex($json_body, $api_secret);
        $coinspaid->validate_signature($provided_signature, $json_body);
        is 1, 0, 'should not reach here';
    } catch ($e) {
        like $e, qr/Coinspaid: api secret is missing/, 'should die when signature keys are not found in config';
    }

    #case when valid signature is passed
    $mocked_coinspaid->mock(
        signature_keys => sub {
            return {secret_key => $api_secret};
        },
    );
    $provided_signature = hmac_sha512_hex($json_body, $api_secret);
    is $coinspaid->validate_signature($provided_signature, $json_body), 1, 'Correct result when authentic signature is passed';

    #case when valid signature is passed but json is empty/undef
    $json_body          = undef;
    $provided_signature = hmac_sha512_hex($json_body // '', $api_secret);
    is $coinspaid->validate_signature($provided_signature, $json_body), 1, 'Correct result when authentic signature is passed but json is empty';

    $mocked_coinspaid->unmock_all();
};

subtest 'transform_status' => sub {
    my $coinspaid = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor->new(processor_name => 'Coinspaid');

    my $status = undef;
    is $coinspaid->transform_status($status), undef, 'Correct response from transform_status when status passed is empty/undef';

    $status = 'some_random_status';
    is $coinspaid->transform_status($status), 'some_random_status', 'Correct response from transform_status when status not found in mapping';

    $status = 'not_confirmed';
    my $mapped_status = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Coinspaid::STATUS_MAPPING->{$status};
    is $coinspaid->transform_status($status), $mapped_status, 'Correct response from transform_status for passed status';
};

subtest 'transform_currency' => sub {
    my $coinspaid = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor->new(processor_name => 'Coinspaid');

    my $currency = undef;
    is $coinspaid->transform_currency($currency), undef, 'Correct response from transform_currency when currency passed is empty/undef';

    $currency = 'abcdef';
    is $coinspaid->transform_currency($currency), $currency, 'Correct response from transform_currency when currency not found in mapping';

    $currency = 'USDTT';
    my $mapped_currency = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Coinspaid::CURRENCY_MAPPING->{$currency};
    is $coinspaid->transform_currency($currency), $mapped_currency, 'Correct response from transform_currency for passed currency';
};

subtest 'process_deposit' => sub {
    #cases when fields missing in payload
    my $cases = [{
            payload => {id    => undef},
            error   => {error => 'id not found in payload'},
        },
        {
            payload => {
                id           => 123,
                transactions => [],
            },
            error => {error => 'transactions not found in payload'},
        },
        {
            payload => {
                id           => 123,
                transactions => [{address => 'address1'}],
            },
            error => {error => 'fees not found in payload'},
        },
        {
            payload => {
                id           => 123,
                transactions => [{address => 'address1'}],
                fees         => [{amount  => .01}]
            },
            error => {error => 'status not found in payload'},
        }];

    for my $case ($cases->@*) {
        my $coinspaid = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor->new(processor_name => 'Coinspaid');
        is_deeply $coinspaid->process_deposit($case->{payload}), $case->{error}, 'Correct error: ' . ($case->{error}{error} // '');
    }

    #cases when fields missing in transactions array of payload
    $cases = [{
            payload => {
                id           => 123,
                transactions => [{txid   => 'txid1'}],
                fees         => [{amount => .01}],
                status       => 'pending',
            },
            error => {error => 'address not found in payload, coinspaid_id: 123'},
        },
        {
            payload => {
                id           => 123,
                transactions => [{address => 'address1'}],
                fees         => [{amount  => .01}],
                status       => 'pending',
            },
            error => {error => 'currency not found in payload, coinspaid_id: 123'},
        },
        {
            payload => {
                id           => 123,
                transactions => [{
                        address  => 'address1',
                        currency => 'USDTT',
                    }
                ],
                fees   => [{amount => .01}],
                status => 'pending',
            },
            error => {error => 'txid not found in payload, coinspaid_id: 123'},
        },
        {
            payload => {
                id           => 123,
                transactions => [{
                        address  => 'address1',
                        currency => 'USDTT',
                        txid     => 'tx_hash1',
                    }
                ],
                fees   => [{amount => .01}],
                status => 'pending',
            },
            error => {error => 'amount not found in payload, coinspaid_id: 123'},
        },
    ];

    for my $case ($cases->@*) {
        my $coinspaid = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor->new(processor_name => 'Coinspaid');
        is_deeply $coinspaid->process_deposit($case->{payload}), $case->{error}, 'Correct error: ' . ($case->{error}{error} // '');
    }

    #case when deposit normalized successfully
    my $payload = {
        id           => 123,
        transactions => [{
                address  => 'address1',
                currency => 'USDTT',
                txid     => 'tx_hash1',
                amount   => 10
            }
        ],
        fees => [{
                type   => 'mining',
                amount => 0.02
            },
            {
                type   => 'deposit',    #as per the check, this should be assigned to fees
                amount => 0.01
            },
            {
                type   => 'deposit',
                amount => 0.03
            }
        ],
        status => 'confirmed',
    };
    my $normalize_txn = {
        trace_id        => 123,
        status          => 'confirmed',
        error           => '',
        address         => 'address1',
        amount          => 10,
        currency        => 'tUSDT',
        hash            => 'tx_hash1',
        transaction_fee => 0.01,
    };

    my $expected_result = {
        is_success   => 1,
        transactions => [$normalize_txn],
    };
    my $coinspaid = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor->new(processor_name => 'Coinspaid');
    is_deeply $coinspaid->process_deposit($payload), $expected_result, 'Correct response for valid payload for deposit txn';

};

subtest 'process_withdrawal' => sub {
    #cases when fields missing in payload
    my $cases = [{
            payload => {id    => undef},
            error   => {error => 'id not found in payload'},
        },
        {
            payload => {
                id => 123,
            },
            error => {error => 'foreign_id not found in payload'},
        },
        {
            payload => {
                id         => 123,
                foreign_id => 4567,
            },
            error => {error => 'transactions not found in payload'},
        },
        {
            payload => {
                id           => 123,
                foreign_id   => 4567,
                transactions => [{address => 'address1'}],
            },
            error => {error => 'fees not found in payload'},
        },
        {
            payload => {
                id           => 123,
                foreign_id   => 4567,
                transactions => [{address => 'address1'}],
                fees         => [{amount  => .091}]
            },
            error => {error => 'status not found in payload'},
        }];

    for my $case ($cases->@*) {
        my $coinspaid = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor->new(processor_name => 'Coinspaid');
        is_deeply $coinspaid->process_withdrawal($case->{payload}), $case->{error}, 'Correct error: ' . ($case->{error}{error} // '');
    }

    #cases when fields missing in transactions array of payload
    $cases = [{
            payload => {
                id           => 123,
                foreign_id   => 4567,
                transactions => [{txid   => 'txid1'}],
                fees         => [{amount => .091}],
                status       => 'pending',
            },
            error => {error => 'address not found in payload, coinspaid_id: 123'},
        },
        {
            payload => {
                id           => 123,
                foreign_id   => 4567,
                transactions => [{address => 'address1'}],
                fees         => [{amount  => .091}],
                status       => 'pending',
            },
            error => {error => 'currency not found in payload, coinspaid_id: 123'},
        },
        {
            payload => {
                id           => 123,
                foreign_id   => 4567,
                transactions => [{
                        address  => 'address1',
                        currency => 'USDTT',
                    }
                ],
                fees   => [{amount => .091}],
                status => 'pending',
            },
            error => {error => 'txid not found in payload, coinspaid_id: 123'},
        },
        {
            payload => {
                id           => 123,
                foreign_id   => 4567,
                transactions => [{
                        address  => 'address1',
                        currency => 'USDTT',
                        txid     => 'tx_hash1',
                    }
                ],
                fees   => [{amount => .091}],
                status => 'pending',
            },
            error => {error => 'amount not found in payload, coinspaid_id: 123'},
        },
    ];

    for my $case ($cases->@*) {
        my $coinspaid = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor->new(processor_name => 'Coinspaid');
        is_deeply $coinspaid->process_withdrawal($case->{payload}), $case->{error}, 'Correct error: ' . ($case->{error}{error} // '');
    }

    #case when withdrawal normalized successfully
    my $payload = {
        id           => 123,
        foreign_id   => 4567,
        transactions => [{
                address  => 'address1',
                currency => 'USDTT',
                txid     => 'tx_hash1',
                amount   => 12
            }
        ],
        fees => [{
                type   => 'mining',
                amount => 0.02
            },
            {
                type   => 'withdrawal',    #as per the check, this should be assigned to fees
                amount => 0.091
            },
            {
                type   => 'withdrawal',
                amount => 0.03
            }
        ],
        status => 'confirmed',
    };
    my $normalize_txn = {
        trace_id        => 123,
        reference_id    => 4567,
        status          => 'confirmed',
        error           => '',
        address         => 'address1',
        amount          => 12,
        currency        => 'tUSDT',
        hash            => 'tx_hash1',
        transaction_fee => 0.091,
    };

    my $expected_result = {
        is_success   => 1,
        transactions => [$normalize_txn],
    };
    my $coinspaid = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor->new(processor_name => 'Coinspaid');
    is_deeply $coinspaid->process_withdrawal($payload), $expected_result, 'Correct response for valid payload for withdrawal txn';
};

done_testing;
