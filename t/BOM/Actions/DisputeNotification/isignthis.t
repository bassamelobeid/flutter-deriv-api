use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::MockModule;
use Log::Any::Test;
use Log::Any qw($log);

use Email::Address::UseXS;
use BOM::Test::Email;

use BOM::Event::Process;
my %payloads = (
    fraud_new => {
        provider => 'isignthis',
        data     => {
            card_reference => {
                card_brand   => "VISA",
                expiry_date  => 1222,
                masked_pan   => "411111....1111",
                recurring_id => "f7fb955_15fc0a831d7__7fa7",
            },
            compound_state => "SUCCESS.COMPLETE",
            event          => "fraud_flagged",
            id             => "885e3506-eb13-4d2c-bc24-e336aaf94037",
            identity       => {
                created_at                      => "2016-11-26T23:34:51.301Z",
                credit_ledger_lifetime_amount   => 14625,
                credit_ledger_lifetime_currency => "EUR",
                download_url                    => "https://gateway.isignthis.com/v1/identity/_b103fc0_158a2f3a950__7e12",
                id                              => "_b103fc0_158a2f3a950__7e12",
                kyc_state                       => "NONE",
                ledger_lifetime_amount          => 63828,
                ledger_lifetime_currency        => "EUR",
            },
            mode             => "registration",
            original_message => {
                account => {
                    ext        => {},
                    identifier => "Test_ID"
                },
                merchant_id    => "widgets-pty-ltd",
                reference      => "256b4622-ea1d-4af0-8326-a276a0627810",
                transaction_id => "6efa5fac-89de-4e75-a2f9-4d34333e7cf1",
            },
            payment_amount => {
                amount   => 3100,
                currency => "EUR"
            },
            payment_provider_responses => [{
                    operation_successful    => 1,
                    operation_type          => "authorization-and-capture",
                    provider_name           => "ISXPay",
                    provider_reference_code => 1111111111,
                    provider_type           => "credit_card",
                    reference_code          => 349351111111111111,
                    request_currency        => "EUR",
                    response_id             => 11111111111,
                    status_code             => "OK000",
                    status_description      => "Success",
                },
            ],
            recurring_transaction     => 0,
            response_code             => "00",
            response_code_description => "Approved and completed successfully",
            secret                    => "083daa84-77b6-4817-a4f3-5771779c1c82",
            state                     => "SUCCESS",
            test_transaction          => 'fix',
            workflow_state            => {
                "3ds"     => "SUCCESS",
                "capture" => "SUCCESS",
                "charge"  => "SUCCESS",
                "credit"  => "NA",
                "docs"    => "NA",
                "kyc"     => "NA",
                "piv"     => "SUCCESS",
                "sca"     => "SUCCESS",
            },
        }
    },
    dispute_new => {
        provider => 'isignthis',
        data     => {
            card_reference => {
                card_brand   => "VISA",
                expiry_date  => 1222,
                masked_pan   => "411111....1111",
                recurring_id => "f7fb955_15fc0a831d7__7fa7",
            },
            compound_state => "SUCCESS.COMPLETE",
            event          => "dispute_flagged",
            id             => "885e3506-eb13-4d2c-bc24-e336aaf94037",
            identity       => {
                created_at                      => "2016-11-26T23:34:51.301Z",
                credit_ledger_lifetime_amount   => 14625,
                credit_ledger_lifetime_currency => "EUR",
                download_url                    => "https://gateway.isignthis.com/v1/identity/_b103fc0_158a2f3a950__7e12",
                id                              => "_b103fc0_158a2f3a950__7e12",
                kyc_state                       => "NONE",
                ledger_lifetime_amount          => 63828,
                ledger_lifetime_currency        => "EUR",
            },
            mode             => "registration",
            original_message => {
                account => {
                    ext        => {},
                    identifier => "Test_ID"
                },
                merchant_id    => "widgets-pty-ltd",
                reference      => "256b4622-ea1d-4af0-8326-a276a0627810",
                transaction_id => "6efa5fac-89de-4e75-a2f9-4d34333e7cf1",
            },
            payment_amount => {
                amount   => 3100,
                currency => "EUR"
            },
            payment_provider_responses => [{
                    operation_successful    => 1,
                    operation_type          => "authorization-and-capture",
                    provider_name           => "ISXPay",
                    provider_reference_code => 1111111111,
                    provider_type           => "credit_card",
                    reference_code          => 349351111111111111,
                    request_currency        => "EUR",
                    response_id             => 11111111111,
                    status_code             => "OK000",
                    status_description      => "Success",
                },
            ],
            recurring_transaction     => 0,
            response_code             => "00",
            response_code_description => "Approved and completed successfully",
            secret                    => "083daa84-77b6-4817-a4f3-5771779c1c82",
            state                     => "SUCCESS",
            test_transaction          => 'fix',
            workflow_state            => {
                "3ds"     => "SUCCESS",
                "capture" => "SUCCESS",
                "charge"  => "SUCCESS",
                "credit"  => "NA",
                "docs"    => "NA",
                "kyc"     => "NA",
                "piv"     => "SUCCESS",
                "sca"     => "SUCCESS",
            },
        }});

my $unsupported_event = {
    provider => 'isignthis',
    data     => {
        event       => 'some_random_event',
        other_fiels => "they doesn't matter"
    },
};

my $mocked_datadog = Test::MockModule->new('DataDog::DogStatsd::Helper');
my @datadog_args;
$mocked_datadog->redefine('stats_inc', sub { @datadog_args = @_ });

subtest 'iSignThis sent events' => sub {
    for my $event (keys %payloads) {
        my $action_handler = BOM::Event::Process::get_action_mappings()->{dispute_notification};
        my @emails_sent;

        BOM::Test::Email::mailbox_clear();
        @emails_sent = BOM::Test::Email::email_list();
        is scalar @emails_sent, 0, 'Intially no e-mail was sent';
        $action_handler->($payloads{$event});

        @emails_sent = BOM::Test::Email::email_list();

        is scalar @emails_sent, 1, 'An e-mail sent';
    }
};

subtest 'Unsupported iSignThis event' => sub {
    my $action_handler = BOM::Event::Process::get_action_mappings()->{dispute_notification};
    my @emails_sent;

    BOM::Test::Email::mailbox_clear();
    @emails_sent = BOM::Test::Email::email_list();
    is scalar @emails_sent, 0, 'Intially no e-mail was sent';

    lives_ok { $action_handler->($unsupported_event) } "Sub don't dies on unsupported event";

    is $datadog_args[0], "event.dispute_notification.isignthis.unsupported." . $unsupported_event->{data}->{event},
        'Stat for iSignThis unsupported event is increased';

    @emails_sent = BOM::Test::Email::email_list();

    is scalar @emails_sent, 0, 'No e-mail sent';
};
done_testing();
