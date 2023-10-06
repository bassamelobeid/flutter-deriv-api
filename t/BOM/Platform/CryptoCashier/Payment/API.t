#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw(create_client top_up);
use BOM::Test::Helper::ExchangeRates           qw(populate_exchange_rates);
use BOM::Test::Helper::Utility                 qw(random_email_address);

use BOM::Platform::CryptoCashier::Payment::API;
use BOM::Platform::CryptoCashier::Payment::Error qw(create_error);

use Digest::HMAC;
use Format::Util::Numbers qw(financialrounding);
use JSON::MaybeUTF8       qw(:v1);

my $mocked_user       = Test::MockModule->new('BOM::User::Client');
my $mocked_API        = Test::MockModule->new('BOM::Platform::CryptoCashier::Payment::API');
my $mocked_event      = Test::MockModule->new('BOM::Platform::Event::Emitter');
my $mocked_controller = Test::MockModule->new('BOM::Platform::CryptoCashier::Payment::API::Controller');

my $dd_metrics = {};
$mocked_API->mock(
    stats_timing => sub {
        my $metric = shift;
        $dd_metrics->{stats_timing}{$metric}++;
    },
    stats_inc => sub {
        my $metric = shift;
        $dd_metrics->{stats_inc}{$metric}++;
    },
);

my $currency = 'BTC';
populate_exchange_rates({$currency => 100});

my $t = Test::Mojo->new('BOM::Platform::CryptoCashier::Payment::API');

my $user = BOM::User->create(
    email    => random_email_address,
    password => 'test',
);
my $crypto_client = create_client();
$crypto_client->set_default_account($currency);
$crypto_client->save();
$user->add_client($crypto_client);
my $crypto_loginid = $crypto_client->loginid;

my $secret = $ENV{CRYPTO_PAYMENT_API_SECRET_TOKEN} = 'dummy_token';

subtest 'Invalid signature' => sub {
    my $expected_content = 'Invalid signature.';

    $t->post_ok('/' => json => {})->status_is(401, 'No X-Signature header')->content_is($expected_content);
    $t->post_ok('/' => {'X-Signature' => 'dummy'} => json => {})->status_is(401, 'Wrong Signature')->content_is($expected_content);

    test_dd({
        stats_timing => {'bom_platform.crypto_cashier_paymentapi.call'         => 2},
        stats_inc    => {'bom_platform.crypto_cashier_paymentapi.no_signature' => 1},
    });
};

subtest 'Invalid request' => sub {
    my $expected_content  = 'Invalid request.';
    my $post_data_encoded = encode_json_utf8({});
    my $signature         = create_signature($post_data_encoded);

    $t->post_ok('/' => {'X-Signature' => $signature} => $post_data_encoded)->status_is(404, 'Endpoint not exists')->content_is($expected_content);
    $t->get_ok('/v1/payment/deposit' => {'X-Signature' => $signature} => $post_data_encoded)->status_is(404, 'Wrong Http method')
        ->content_is($expected_content);

    test_dd({
        stats_timing => {'bom_platform.crypto_cashier_paymentapi.call' => 2},
    });
};

subtest "/v1/payment/deposit" => sub {
    my $body = {
        crypto_id        => 1,
        address          => 'address_hash',
        transaction_hash => 'tx_hash',
        amount           => 1,
        client_loginid   => $crypto_loginid,
        currency_code    => 'BTC',
    };

    subtest "missing requier parameter" => sub {
        for my $field (keys %$body) {
            my $value = $body->{$field};
            delete $body->{$field};
            my $error = create_error('MissingRequiredParameter', message_params => $field);
            call_ok('post' => '/v1/payment/deposit' => $body)->has_error->error_code_is('MissingRequiredParameter')
                ->error_message_like($error->{message});
            $body->{$field} = $value;
        }
    };

    subtest "init_payment_validation" => sub {
        subtest "No client found" => sub {
            my $old_value = $body->{client_loginid};
            $body->{client_loginid} = 'CR123';

            my $error = create_error('ClientNotFound', message_params => 'CR123');
            call_ok('post' => '/v1/payment/deposit' => $body)->has_error->error_code_is('ClientNotFound')->error_message_like($error->{message});

            $body->{client_loginid} = $old_value;
        };

        subtest "Invalid currency" => sub {
            my $old_value = $body->{currency_code};
            $body->{currency_code} = 'USD';

            my $error = create_error('InvalidCurrency', message_params => 'USD');
            call_ok('post' => '/v1/payment/deposit' => $body)->has_error->error_code_is('InvalidCurrency')->error_message_like($error->{message});

            $body->{currency_code} = $old_value;
        };

        subtest "wrong currency" => sub {
            my $old_value = $body->{currency_code};
            $body->{currency_code} = 'ETH';

            my $error = create_error('CurrencyNotMatch', message_params => 'ETH');
            call_ok('post' => '/v1/payment/deposit' => $body)->has_error->error_code_is('CurrencyNotMatch')->error_message_like($error->{message});

            $body->{currency_code} = $old_value;
        };

        subtest "incorrect loginid with no sibling account" => sub {
            $body->{client_loginid} = undef;

            # create random account
            my $user2 = BOM::User->create(
                email    => random_email_address,
                password => 'test',
            );
            my $random_crypto_client = create_client();
            $random_crypto_client->set_default_account('ETH');
            $random_crypto_client->save();
            $user2->add_client($random_crypto_client);
            my $random_crypto_loginid = $random_crypto_client->loginid;

            $body->{incorrect_loginid} = $random_crypto_loginid;

            my $error = create_error('SiblingAccountNotFound', message_params => $body->{crypto_id});
            call_ok('post' => '/v1/payment/deposit' => $body)->has_error->error_code_is('SiblingAccountNotFound')
                ->error_message_like($error->{message});

            $body->{client_loginid}    = $crypto_loginid;
            $body->{incorrect_loginid} = undef;
        };

        subtest "incorrect loginid with correct sibling account" => sub {
            $body->{client_loginid} = undef;
            my $old_value = $body->{crypto_id};
            $body->{crypto_id} = 2;

            # create sibling account
            my $sibling_crypto_client = create_client();
            $sibling_crypto_client->set_default_account('ETH');
            $sibling_crypto_client->save();
            $user->add_client($sibling_crypto_client);
            my $sibling_crypto_loginid = $sibling_crypto_client->loginid;

            $body->{incorrect_loginid} = $sibling_crypto_loginid;

            $mocked_event->mock(
                emit => sub {
                    my ($event, $event_body) = @_;
                    return 1;
                },
            );

            call_ok('post' => '/v1/payment/deposit' => $body)->has_no_error;

            my $controller = BOM::Platform::CryptoCashier::Payment::API::Controller->new;
            my $payment_id = $controller->get_payment_id_from_clientdb($sibling_crypto_loginid, $body->{crypto_id}, 'deposit');
            $t->json_is(
                '' => {
                    payment_id     => $payment_id,
                    client_loginid => $crypto_loginid
                },
                'right object'
            );

            $body->{client_loginid}    = $crypto_loginid;
            $body->{incorrect_loginid} = undef;
            $body->{crypto_id}         = $old_value;

            $mocked_event->unmock_all;

        };

        subtest "zero amount" => sub {
            my $old_value = $body->{amount};
            $body->{amount} = 0.000000004;

            my $error = create_error('ZeroPaymentAmount');
            call_ok('post' => '/v1/payment/deposit' => $body)->has_error->error_code_is('ZeroPaymentAmount')->error_message_like($error->{message});

            $body->{amount} = $old_value;
        };
    };

    subtest "Failed to credit" => sub {
        $mocked_user->mock(
            payment_ctc => sub {
                return undef;
            },
        );

        my $error = create_error('FailedCredit', message_params => $body->{crypto_id});
        call_ok('post' => '/v1/payment/deposit' => $body)->has_error->error_code_is('FailedCredit')->error_message_like($error->{message});

        $mocked_user->unmock_all;
    };

    subtest "Credit successfully after rounding the amount" => sub {
        my $expected_event_body = {
            loginid          => $body->{client_loginid},
            is_first_deposit => 0,
            amount           => financialrounding('amount', $body->{currency_code}, $body->{amount}),
            currency         => $body->{currency_code},
            remark           => $body->{address},
        };

        my $event;
        my $event_body;
        $mocked_event->mock(
            emit => sub {
                ($event, $event_body) = @_;
                return 1;
            },
        );

        call_ok('post' => '/v1/payment/deposit' => $body)->has_no_error;

        my $controller = BOM::Platform::CryptoCashier::Payment::API::Controller->new;
        my $payment_id = $controller->get_payment_id_from_clientdb($body->{client_loginid}, $body->{crypto_id}, 'deposit');
        $t->json_is(
            '' => {
                payment_id     => $payment_id,
                client_loginid => $crypto_loginid
            },
            'right object'
        );

        is $event, 'payment_deposit', 'Correct event emitted';
        is_deeply $event_body, $expected_event_body, 'Correct event body';

        $mocked_event->unmock_all;
    };

    subtest "Payment already processed" => sub {
        # already credited in the previous subtest
        my $controller = BOM::Platform::CryptoCashier::Payment::API::Controller->new;
        my $payment_id = $controller->get_payment_id_from_clientdb($body->{client_loginid}, $body->{crypto_id}, 'deposit');

        call_ok('post' => '/v1/payment/deposit' => $body)
            ->has_no_error->response_is_deeply({payment_id => $payment_id, client_loginid => $crypto_loginid});
    };
};

subtest "/v1/payment/withdraw" => sub {
    my $body = {
        crypto_id      => 1,
        address        => 'address_hash',
        amount         => 1,
        client_loginid => $crypto_loginid,
        currency_code  => 'BTC',
    };

    subtest "missing requier parameter" => sub {
        for my $field (keys %$body) {
            my $value = $body->{$field};
            delete $body->{$field};
            my $error = create_error('MissingRequiredParameter', message_params => $field);
            call_ok('post' => '/v1/payment/withdraw' => $body)->has_error->error_code_is('MissingRequiredParameter')
                ->error_message_like($error->{message});
            $body->{$field} = $value;
        }
    };

    subtest "init_payment_validation" => sub {
        subtest "No client found" => sub {
            my $old_value = $body->{client_loginid};
            $body->{client_loginid} = 'CR123';

            my $error = create_error('ClientNotFound', message_params => 'CR123');
            call_ok('post' => '/v1/payment/withdraw' => $body)->has_error->error_code_is('ClientNotFound')->error_message_like($error->{message});

            $body->{client_loginid} = $old_value;
        };

        subtest "Invalid currency" => sub {
            my $old_value = $body->{currency_code};
            $body->{currency_code} = 'USD';

            my $error = create_error('InvalidCurrency', message_params => 'USD');
            call_ok('post' => '/v1/payment/withdraw' => $body)->has_error->error_code_is('InvalidCurrency')->error_message_like($error->{message});

            $body->{currency_code} = $old_value;
        };

        subtest "wrong currency" => sub {
            my $old_value = $body->{currency_code};
            $body->{currency_code} = 'ETH';

            my $error = create_error('CurrencyNotMatch', message_params => 'ETH');
            call_ok('post' => '/v1/payment/withdraw' => $body)->has_error->error_code_is('CurrencyNotMatch')->error_message_like($error->{message});

            $body->{currency_code} = $old_value;
        };

        subtest "zero amount" => sub {
            my $old_value = $body->{amount};
            $body->{amount} = 0.000000004;

            my $error = create_error('ZeroPaymentAmount');
            call_ok('post' => '/v1/payment/withdraw' => $body)->has_error->error_code_is('ZeroPaymentAmount')->error_message_like($error->{message});

            $body->{amount} = $old_value;
        };
    };

    subtest "Invalid payment" => sub {
        $mocked_user->mock(
            validate_payment => sub {
                die {message_to_client => 'error_message'};
            },
        );

        my $error = create_error('InvalidPayment', message_params => 'error_message');

        call_ok('post' => '/v1/payment/withdraw' => $body)->has_error->error_code_is('InvalidPayment')->error_message_like($error->{message});

        $mocked_user->unmock_all;
    };

    subtest "Failed to debit" => sub {
        $mocked_user->mock(
            validate_payment => sub {
                return undef;
            },
            payment_ctc => sub {
                return undef;
            },
        );

        my $error = create_error('FailedDebit', message_params => $body->{crypto_id});
        call_ok('post' => '/v1/payment/withdraw' => $body)->has_error->error_code_is('FailedDebit')->error_message_like($error->{message});

        $mocked_user->unmock_all;
    };

    subtest "Debit successfully after rounding the amount" => sub {
        $mocked_user->mock(
            validate_payment => sub {
                return undef;
            },
        );

        call_ok('post' => '/v1/payment/withdraw' => $body)->has_no_error;

        my $controller = BOM::Platform::CryptoCashier::Payment::API::Controller->new;
        my $payment_id = $controller->get_payment_id_from_clientdb($body->{client_loginid}, $body->{crypto_id}, 'withdrawal');
        $t->json_is(
            '' => {payment_id => $payment_id},
            'right object'
        );

        $mocked_user->unmock_all;
    };

    subtest "Payment already processed" => sub {
        # already credited in the previous subtest
        my $controller = BOM::Platform::CryptoCashier::Payment::API::Controller->new;
        my $payment_id = $controller->get_payment_id_from_clientdb($body->{client_loginid}, $body->{crypto_id}, 'withdrawal');

        call_ok('post' => '/v1/payment/withdraw' => $body)->has_no_error->response_is_deeply({payment_id => $payment_id});
    };
};

subtest "/v1/payment/revert_withdrawal" => sub {
    my $body = {
        crypto_id      => 3,
        address        => 'address_hash',
        amount         => 1,
        currency_code  => 'BTC',
        client_loginid => $crypto_loginid,
    };

    subtest "missing required parameter" => sub {

        for my $field (keys %$body) {
            my $value = $body->{$field};
            delete $body->{$field};
            my $error = create_error('MissingRequiredParameter', message_params => $field);
            call_ok('post' => '/v1/payment/revert_withdrawal' => $body)->has_error->error_code_is('MissingRequiredParameter')
                ->error_message_like($error->{message});
            $body->{$field} = $value;
        }
    };

    subtest "init_payment_validation" => sub {
        subtest "No client found" => sub {
            my $old_value = $body->{client_loginid};
            $body->{client_loginid} = 'CR123';

            my $error = create_error('ClientNotFound', message_params => 'CR123');
            call_ok('post' => '/v1/payment/revert_withdrawal' => $body)->has_error->error_code_is('ClientNotFound')
                ->error_message_like($error->{message});

            $body->{client_loginid} = $old_value;
        };
        subtest "Invalid currency" => sub {
            my $old_value = $body->{currency_code};
            $body->{currency_code} = 'USD';

            my $error = create_error('InvalidCurrency', message_params => 'USD');
            call_ok('post' => '/v1/payment/revert_withdrawal' => $body)->has_error->error_code_is('InvalidCurrency')
                ->error_message_like($error->{message});

            $body->{currency_code} = $old_value;
        };

        subtest "wrong currency" => sub {
            my $old_value = $body->{currency_code};
            $body->{currency_code} = 'ETH';

            my $error = create_error('CurrencyNotMatch', message_params => 'ETH');
            call_ok('post' => '/v1/payment/revert_withdrawal' => $body)->has_error->error_code_is('CurrencyNotMatch')
                ->error_message_like($error->{message});

            $body->{currency_code} = $old_value;
        };

        subtest "zero amount" => sub {
            my $old_value = $body->{amount};
            $body->{amount} = 0.000000004;

            my $error = create_error('ZeroPaymentAmount');
            call_ok('post' => '/v1/payment/revert_withdrawal' => $body)->has_error->error_code_is('ZeroPaymentAmount')
                ->error_message_like($error->{message});

            $body->{amount} = $old_value;
        };

    };

    subtest "Failed to revert withdrawal - MissingWithdrawalPayment" => sub {

        my $error = create_error('MissingWithdrawalPayment', message_params => $body->{crypto_id});
        call_ok('post' => '/v1/payment/revert_withdrawal' => $body)->has_error->error_code_is('MissingWithdrawalPayment')
            ->error_message_like($error->{message});

    };

    subtest "Failed to revert withdrawal" => sub {
        $mocked_user->mock(
            payment_ctc => sub {
                return undef;
            },
        );

        $mocked_controller->mock(
            get_payment_id_from_clientdb => sub {
                my ($self, $client_loginid, $crypto_id, $transaction_type) = @_;

                return 4 if ($transaction_type eq 'withdrawal');
            });

        my $error = create_error('FailedRevert', message_params => $body->{crypto_id});
        call_ok('post' => '/v1/payment/revert_withdrawal' => $body)->has_error->error_code_is('FailedRevert')->error_message_like($error->{message});

        $mocked_user->unmock_all;
        $mocked_controller->unmock_all;
    };

    subtest "Withdrawal reverted successfully" => sub {

        $mocked_user->mock(
            validate_payment => sub {
                return undef;
            },
        );

        call_ok('post' => '/v1/payment/withdraw' => $body)->has_no_error;

        call_ok('post' => '/v1/payment/revert_withdrawal' => $body)->has_no_error;

        my $controller = BOM::Platform::CryptoCashier::Payment::API::Controller->new;
        my $payment_id = $controller->get_payment_id_from_clientdb($body->{client_loginid}, $body->{crypto_id}, 'withdraw_revert');
        $t->json_is(
            '' => {payment_id => $payment_id},
            'right object'
        );

        $mocked_user->unmock_all;
    };

    subtest "withdraw_revert already processed" => sub {
        # already reverted in the previous subtest
        my $controller = BOM::Platform::CryptoCashier::Payment::API::Controller->new;
        my $payment_id = $controller->get_payment_id_from_clientdb($body->{client_loginid}, $body->{crypto_id}, 'withdraw_revert');

        call_ok('post' => '/v1/payment/revert_withdrawal' => $body)->has_no_error->response_is_deeply({payment_id => $payment_id});

    };
};

$mocked_API->unmock_all;

done_testing;

sub create_signature {
    my $req_data_encoded = shift;

    my $sig = do {
        my $digest = Digest::HMAC->new(($secret), 'Digest::SHA1');
        $digest->add($req_data_encoded);
        $digest->hexdigest;
    };

    return $sig;
}

sub test_dd {
    my ($expected, $description) = @_;

    $description //= 'Correct DD metrics';
    is_deeply $dd_metrics, $expected, $description;

    $dd_metrics = {};
}

sub call_ok {
    my ($method, $endpoint, $post_data, $description) = @_;
    $description //= 'Returns response with correct content type as JSON';
    $method = $method . '_ok';

    my $post_data_encoded = encode_json_utf8($post_data);
    my $signature         = create_signature($post_data_encoded);

    $t->$method($endpoint => {'X-Signature' => $signature} => $post_data_encoded)->status_is(200)
        ->content_type_like(qr{application/json}, $description);
    return __PACKAGE__;
}

sub has_error {
    my ($self, $description) = @_;
    $description //= 'Returns error with correct structure';
    $self->response_contains({
            error => {
                code    => '^\\w+',
                message => '^\\w+',
            }
        },
        $description,
        1,
    );
    return $self;
}

sub has_no_error {
    my ($self, $description) = @_;
    $description //= 'Returns no error';
    $t->json_hasnt('/error', $description);
    return $self;
}

sub error_code_is {
    my ($self, $error_code, $description) = @_;
    $description //= "Returns correct error code: '$error_code'";
    $t->json_is('/error/code', $error_code, $description);
    return $self;
}

sub error_message_like {
    my ($self, $error_message, $description) = @_;
    $description //= "Returns correct error message: '$error_message'";
    $t->json_like('/error/message', qr/$error_message/i, $description);
    return $self;
}

sub response_contains {
    my ($self, $expected_response, $description, $should_hide_structure, $parent_path) = @_;

    $description //= 'Returns the response containing the expected structure.';

    note "--> expected:\n", explain $expected_response unless $parent_path || $should_hide_structure;

    for my $key (keys $expected_response->%*) {
        my $key_path = ($parent_path ? "$parent_path/" : '') . $key;

        if (ref $expected_response->{$key}) {
            $self->response_contains($expected_response->{$key}, undef, $should_hide_structure, $key_path);
        } else {
            $t->json_like("/$key_path", qr/$expected_response->{$key}/i, $description . ' ' . $key_path =~ s/\//->/gr);
            note "--> got:\n", explain $t->tx->res->json() unless $t->success;
        }
    }

    return $self;
}

sub response_is_deeply {
    my ($self, $expected_response, $description) = @_;

    $description //= 'Returns expected response deeply matching the expected result.';

    note "--> expected:\n", explain $expected_response;

    $t->json_is(
        json => $expected_response,
        $description
    );

    return $self;
}
