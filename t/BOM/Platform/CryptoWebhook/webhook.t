use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::MockModule;

use BOM::Platform::CryptoWebhook::Webhook;

my $mocked_webhook            = Test::MockModule->new('BOM::Platform::CryptoWebhook::Webhook');
my $mocked_webhook_controller = Test::MockModule->new('BOM::Platform::CryptoWebhook::Webhook::Controller');

my $dd_metrics = {};
my $dd_tags;

$mocked_webhook->mock(
    stats_timing => sub {
        my $metric = shift;
        $dd_metrics->{stats_timing}{$metric}++;
    },
);
$mocked_webhook_controller->mock(
    stats_inc => sub {
        my $metric = shift;
        my $tags   = shift;
        $dd_metrics->{stats_inc}{$metric}++;
        $dd_tags = $tags;
    },
);

my $t = Test::Mojo->new('BOM::Platform::CryptoWebhook::Webhook');

subtest 'Invalid endpoint' => sub {
    my $payload = {id => 123};
    $t->post_ok('/', json => $payload)->status_is(401)->json_is(undef);
    $t->get_ok('/')->status_is(401)->json_is(undef);
    $t->post_ok('/v1/abc_endpoint', json => $payload)->status_is(401)->json_is(undef);
    $t->get_ok('/v1/abc_endpoint')->status_is(401)->json_is(undef);

    test_dd({
            stats_timing => {'bom_platform.crypto_webhook.call' => 4},
        },
        undef,
        'Correct DD metrics for unknown endpoints',
    );
};

subtest '/processor_coinspaid' => sub {
    my $mocked_coinspaid = Test::MockModule->new('BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Coinspaid');
    my $endpoint         = "/api/v1/coinspaid";

    subtest "invalid signature" => sub {
        $mocked_coinspaid->mock(
            validate_signature => sub {
                return 0;
            },
        );
        my $payload = {id => 123};
        $t->post_ok($endpoint, json => $payload)->status_is(401)->json_is(undef);

        test_dd({
                stats_timing => {'bom_platform.crypto_webhook.call'              => 1},
                stats_inc    => {'bom_platform.crypto_webhook.invalid_signature' => 1},
            },
            {tags => ['proccessor:coinspaid']},
            'Correct DD metrics for invalid signature',
        );
    };

    subtest "invalid request" => sub {
        $mocked_coinspaid->mock(
            validate_signature => sub {
                return 1;
            },
        );

        $t->post_ok($endpoint)->status_is(200)->json_is(undef);
        test_dd({
                stats_timing => {'bom_platform.crypto_webhook.call'        => 1},
                stats_inc    => {'bom_platform.crypto_webhook.invalid_req' => 1},
            },
            {tags => ['proccessor:coinspaid']},
            'Correct DD metrics for invalid request when json not passed'
        );

        my $payload = {id => 123};
        $t->post_ok($endpoint, json => $payload)->status_is(200)->json_is(undef);
        test_dd({
                stats_timing => {'bom_platform.crypto_webhook.call'        => 1},
                stats_inc    => {'bom_platform.crypto_webhook.invalid_req' => 1},
            },
            {tags => ['proccessor:coinspaid']},
            'Correct DD metrics for invalid request when json missing required field'
        );

        $payload = {
            type         => 'not_deposit_not_withdrawal',
            id           => 1234,
            transactions => [],
            fees         => [],
            status       => 'cancelled',
        };
        $t->post_ok($endpoint, json => $payload)->status_is(200)->json_is(undef);
        test_dd({
                stats_timing => {'bom_platform.crypto_webhook.call'        => 1},
                stats_inc    => {'bom_platform.crypto_webhook.invalid_req' => 1},
            },
            {tags => ['proccessor:coinspaid']},
            'Correct DD metrics for invalid request when json field "type" has wrong value'
        );
    };

    subtest "invalid_payload" => sub {
        $mocked_coinspaid->mock(
            validate_signature => sub {
                return 1;
            },
            process_deposit => sub {
                return {error => "fees not found in payload"};
            },
            process_withdrawal => sub {
                return {error => "status not found in payload"};
            },
        );

        for my $txn_type (qw/ deposit withdrawal/) {
            my $payload = {
                type         => $txn_type,
                id           => 1234,
                transactions => [],
                fees         => [],
                status       => 'cancelled',
            };
            $t->post_ok($endpoint, json => $payload)->status_is(200)->json_is(undef);
            test_dd({
                    stats_timing => {'bom_platform.crypto_webhook.call' => 1},
                    stats_inc    => {
                        'bom_platform.crypto_webhook.invalid_payload' => 1,
                    },
                },
                {tags => ['proccessor:coinspaid']},
                'Correct DD metrics for invalid request when fields missing from payload'
            );
        }
    };

    subtest "when one event deposit/withdrawal fails in transactions list" => sub {
        my $dummy_txns = [{
                trace_id => 1,
                error    => "",
                address  => "address",
                #....
            },
            {
                trace_id => 122,
                error    => "",
                address  => "address2",
                #....
            }];

        $mocked_coinspaid->mock(
            validate_signature => sub {
                return 1;
            },
            process_deposit => sub {
                return {
                    is_success   => 1,
                    transactions => $dummy_txns
                };
            },
            process_withdrawal => sub {
                return {
                    is_success   => 1,
                    transactions => $dummy_txns
                };
            },
            emit_deposit_event => sub {
                my ($self, $txn) = @_;
                return 1 if $txn->{trace_id} == 1;
                return 0;
            },
            emit_withdrawal_event => sub {
                my ($self, $txn) = @_;
                return 1 if $txn->{trace_id} == 122;
                return 0;
            },

        );

        for my $txn_type (qw/ deposit withdrawal/) {
            my $payload = {
                type         => $txn_type,
                id           => 1234,
                transactions => [],
                fees         => [],
                status       => 'cancelled',
            };
            $t->post_ok($endpoint, json => $payload)->status_is(401)->json_is(undef);

            test_dd({
                    stats_timing => {'bom_platform.crypto_webhook.call' => 1},
                },
                undef,
                'Correct DD metrics when one or more event triggering is failed'
            );
        }
    };

    subtest "when event deposit/withdrawal successfully emitted, and the request returned with 200" => sub {
        my $dummy_txns = [{
                trace_id => 1,
                error    => "",
                address  => "address",
                #....
            },
            {
                trace_id => 122,
                error    => "",
                address  => "address2",
                #....
            }];

        $mocked_coinspaid->mock(
            validate_signature => sub {
                return 1;
            },
            process_deposit => sub {
                return {
                    is_success   => 1,
                    transactions => $dummy_txns
                };
            },
            process_withdrawal => sub {
                return {
                    is_success   => 1,
                    transactions => $dummy_txns
                };
            },
            emit_deposit_event => sub {
                my ($self, $txn) = @_;
                return 1;
            },
            emit_withdrawal_event => sub {
                my ($self, $txn) = @_;
                return 1;
            },

        );

        for my $txn_type (qw/ deposit withdrawal/) {
            my $payload = {
                type         => $txn_type,
                id           => 1234,
                transactions => [],
                fees         => [],
                status       => 'cancelled',
            };
            $t->post_ok($endpoint, json => $payload)->status_is(200)->json_is(undef);

            test_dd({
                    stats_timing => {'bom_platform.crypto_webhook.call' => 1},
                },
                undef,
                'Correct DD metrics when request is returned with 200 code'
            );
        }
    };

    $mocked_coinspaid->unmock_all;
};

subtest "generate_metrics_after_dispatch" => sub {
    my $cases = [{
            endpoint => 'processor_coinspaid',
        },
        {
            endpoint => 'invalid_request',
        },
    ];

    my $t          = Test::Mojo->new('BOM::Platform::CryptoWebhook::Webhook');
    my $controller = $t->app->build_controller;
    $controller->res->{code} = 200;
    my $test_start_time      = Time::HiRes::time;
    my $dd_metric_call_count = 0;                   # number of times data was set to dd

    $controller->stash(BOM::Platform::CryptoWebhook::Webhook::CALL_START_TIME, $test_start_time);

    foreach my $case (@$cases) {
        my ($endpoint, $origin) = ($case->{endpoint}, $case->{origin} // "");

        $controller->stash('action' => $endpoint);

        $mocked_webhook->mock(
            stats_timing => sub {
                my ($metric_name, $execution_time, $params) = @_;
                my $tags = $params->{tags};

                my @expected_tags = ("origin:$origin", "code:200", "endpoint:$endpoint");

                ++$dd_metric_call_count;

                is $metric_name, BOM::Platform::CryptoWebhook::Webhook::DD_METRIC_PREFIX . 'call', "Correct DD metric name for endpoint:$endpoint";
                cmp_ok $execution_time, 'gt', 0.0, 'Correct positive execution time';

                is_deeply $tags, \@expected_tags, 'Correct tags for the DD metric';
            });

        BOM::Platform::CryptoWebhook::Webhook::generate_metrics_after_dispatch($controller);
    }

    is $dd_metric_call_count, @$cases, 'DD metric sent expected number of times';
};

$mocked_webhook->unmock_all;
$mocked_webhook_controller->unmock_all;

sub test_dd {
    my ($expected_metric, $expected_tags, $description) = @_;
    $description //= 'Correct DD metrics';
    is_deeply $dd_metrics, $expected_metric, $description;
    is_deeply $dd_tags,    $expected_tags,   $description if $expected_tags;
    $dd_metrics = {};
    $dd_tags    = undef;
}

done_testing;

