use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;
use Log::Any::Test;
use Log::Any qw($log);

use BOM::Platform::CryptoWebhook::Webhook::Controller;
use Mojo::Message::Request;

my $mocked_webhook_controller = Test::MockModule->new('BOM::Platform::CryptoWebhook::Webhook::Controller');
my $dd_metrics                = {};
my $dd_tags;

$mocked_webhook_controller->mock(
    rendered  => sub { my (undef, $response) = @_; return $response; },
    stats_inc => sub {
        my $metric = shift;
        my $tags   = shift;
        $dd_metrics->{stats_inc}{$metric}++;
        $dd_tags = $tags;
    },
);

subtest 'processor_coinspaid' => sub {
    my $mocked_coinspaid = Test::MockModule->new('BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Coinspaid');
    my $mocked_req       = Test::MockModule->new('Mojo::Message::Request');

    subtest "invalid signature" => sub {
        $mocked_webhook_controller->mock(
            req => sub {
                return Mojo::Message::Request->new;
            },
        );
        $mocked_coinspaid->mock(
            validate_signature => sub {
                return 0;
            },
        );
        my $controller = BOM::Platform::CryptoWebhook::Webhook::Controller->new();
        my $response   = $controller->processor_coinspaid();
        my $error      = $controller->rendered(401);
        cmp_deeply $response, $error, 'Renders the correct error when invalid signature.';
        test_dd({
                stats_inc => {'bom_platform.crypto_webhook.invalid_signature' => 1},
            },
            {tags => ['proccessor:coinspaid']},
            'Correct DD metrics for invalid signature'
        );
    };

    subtest "invalid request" => sub {
        $mocked_webhook_controller->mock(
            req => sub {
                return Mojo::Message::Request->new;
            },
        );
        $mocked_coinspaid->mock(
            validate_signature => sub {
                return 1;
            },
        );

        my $controller = BOM::Platform::CryptoWebhook::Webhook::Controller->new();
        my $response   = $controller->processor_coinspaid();
        my $error      = $controller->rendered(200);
        cmp_deeply $response, $error, 'Renders the correct error when invalid request.';

        test_dd({
                stats_inc => {'bom_platform.crypto_webhook.invalid_req' => 1},
            },
            {tags => ['proccessor:coinspaid']},
            'Correct DD metrics for invalid request when json not passed'
        );

        #case when json is passed but missing required field, eg 'type'
        $mocked_req->mock(
            json => sub {
                return {id => 123};
            },
        );

        $controller = BOM::Platform::CryptoWebhook::Webhook::Controller->new();
        $response   = $controller->processor_coinspaid();
        $error      = $controller->rendered(200);
        cmp_deeply $response, $error, 'Renders the correct error when json missing required field.';
        test_dd({
                stats_inc => {'bom_platform.crypto_webhook.invalid_req' => 1},
            },
            {tags => ['proccessor:coinspaid']},
            'Correct DD metrics for invalid request when json missing required field'
        );

        #case when json field "type" has wrong value
        $mocked_req->mock(
            json => sub {
                return {
                    id   => 123,
                    type => 'not_deposit_not_withdrawal'
                };
            },
        );

        $controller = BOM::Platform::CryptoWebhook::Webhook::Controller->new();
        $response   = $controller->processor_coinspaid();
        $error      = $controller->rendered(200);
        cmp_deeply $response, $error, 'Renders the correct error when json field "type" has wrong value.';
        test_dd({
                stats_inc => {'bom_platform.crypto_webhook.invalid_req' => 1},
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
                return {error => "status not found in payload"};
            },
            process_withdrawal => sub {
                return {error => "status not found in payload"};
            },
        );

        for my $txn_type (qw/ deposit withdrawal/) {
            $mocked_req->mock(
                json => sub {
                    return {
                        id           => 1234,
                        transactions => [],
                        fees         => [],
                        status       => 'cancelled',
                        type         => $txn_type,
                    };
                },
            );
            $log->clear;
            my $controller = BOM::Platform::CryptoWebhook::Webhook::Controller->new();
            my $response   = $controller->processor_coinspaid();
            cmp_bag $log->msgs,
                [{
                    level    => 'info',
                    category => 'BOM::Platform::CryptoWebhook::Webhook::Controller',
                    message  => "Error processing Coinspaid $txn_type. Error: status not found in payload, trace_id: 1234, tx_id: <undef>",
                }
                ],
                "Correct dd info raised for $txn_type case";
            my $error = $controller->rendered(200);
            cmp_deeply $response, $error, 'Renders the correct error when fields missing from payload.';
            test_dd({
                    stats_inc => {'bom_platform.crypto_webhook.invalid_payload' => 1},
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
            $mocked_req->mock(
                json => sub {
                    return {
                        id           => 1234,
                        transactions => [],
                        fees         => [],
                        status       => 'cancelled',
                        type         => $txn_type,
                    };
                },
            );

            my $controller = BOM::Platform::CryptoWebhook::Webhook::Controller->new();
            my $response   = $controller->processor_coinspaid();
            my $error      = $controller->rendered(401);
            cmp_deeply $response, $error, 'Renders the correct error when one or more event triggering is failed.';
            test_dd({}, undef, 'Correct DD metrics when one or more event triggering is failed');
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
            $mocked_req->mock(
                json => sub {
                    return {
                        id           => 1234,
                        transactions => [],
                        fees         => [],
                        status       => 'cancelled',
                        type         => $txn_type,
                    };
                },
            );

            my $controller   = BOM::Platform::CryptoWebhook::Webhook::Controller->new();
            my $response     = $controller->processor_coinspaid();
            my $correct_code = $controller->rendered(200);
            cmp_deeply $response, $correct_code, 'Renders the correct code when one or more event triggering is failed.';
            test_dd({}, undef, 'Correct DD metrics when request is returned with 200 code');
        }
    };

    $mocked_req->unmock_all();
    $mocked_coinspaid->unmock_all();
};

subtest 'render_request_with_dd' => sub {
    my $controller = BOM::Platform::CryptoWebhook::Webhook::Controller->new();
    my $response   = $controller->render_request_with_dd();
    my $error      = $controller->rendered(401);
    cmp_deeply $response, $error, 'Returns the correct error when no params are passed.';

    $controller = BOM::Platform::CryptoWebhook::Webhook::Controller->new();
    $response   = $controller->render_request_with_dd(201, 'coinspaid');      #when only response code & proccessor are passed
    $error      = $controller->rendered(201);
    cmp_deeply $response, $error, 'Returns the correct response when only dd key is passed.';

    $controller = BOM::Platform::CryptoWebhook::Webhook::Controller->new();
    $response   = $controller->render_request_with_dd(200, 'coinspaid', 'invalid_req');    #when all params are paased
    $error      = $controller->rendered(200);
    cmp_deeply $response, $error, 'Returns the correct response when all params are passed .';
    test_dd({
            stats_inc => {'bom_platform.crypto_webhook.invalid_req' => 1},
        },
        {tags => ['proccessor:coinspaid']},
        'Correct DD metrics for invalid_req'
    );
};

subtest 'invalid_request' => sub {
    my $controller = BOM::Platform::CryptoWebhook::Webhook::Controller->new();
    my $response   = $controller->invalid_request();
    my $error      = $controller->rendered(401);
    cmp_deeply $response, $error, 'Returns the correct error code.';
};

$mocked_webhook_controller->unmock_all();

sub test_dd {
    my ($expected_metric, $expected_tags, $description) = @_;
    $description //= 'Correct DD metrics';
    is_deeply $dd_metrics, $expected_metric, $description;
    is_deeply $dd_tags,    $expected_tags,   $description if $expected_tags;
    $dd_metrics = {};
    $dd_tags    = undef;
}

done_testing;
