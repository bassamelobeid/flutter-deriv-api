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
        provider => 'acquired',
        data     => {
            id         => "fea514d1-272d-4fed-bad3-0f4e19e88918",
            timestamp  => "15012018182020",
            company_id => "126",
            mid        => "1187",
            hash       => "B9AE9775EE4A07079191C0E5B96FDBCEF5C964DD17C8AEE03EF6508F3AA27123",
            event      => "fraud_new",
            list       => [{
                    transaction_id    => "10680696",
                    merchant_order_id => "5990700",
                    parent_id         => "",
                    arn               => "74567618008180083399312",
                    rrn               => "720010680696",
                    fraud             => {
                        fraud_id    => "",
                        date        => "2018-01-15",
                        amount      => "130.52",
                        currency    => "USD",
                        auto_refund => 0,
                    },
                    history => {
                        retrieval_id => "",
                        fraud_id     => "",
                        dispute_id   => ""
                    }}]}
    },
    dispute_new => {
        provider => 'acquired',
        data     => {
            id         => "C9EDECD6-D0B5-AED5-48E6-EF235ECD5A54",
            timestamp  => "20200626110608",
            company_id => "207",
            hash       => "282ae91439a1b214046ee8020a641ec1acb969008b68e77ac6e75478331d80f5",
            event      => "dispute_new",
            list       => [{
                    mid               => "1111",
                    transaction_id    => "38311111",
                    merchant_order_id => "1234567_001",
                    parent_id         => "38311109",
                    arn               => "74089120120017577925402",
                    rrn               => "012011111111",
                    dispute           => {
                        dispute_id  => "CB_38317766_334344",
                        reason_code => "10.4",
                        description => "Fraud",
                        date        => "2020-01-01",
                        amount      => "19.95",
                        currency    => "GBP"
                    },
                    history => {
                        retrieval_id => "0",
                        fraud_id     => "0",
                        dispute_id   => "0"
                    }}]}});

my $unsupported_provider = {
    provider => 'acquire_clearly_wrong',
    data     => "doesn't matter it won't be processed",
};
my $unsupported_acquired_event = {
    provider => 'acquired',
    data     => {
        event       => 'some_random_event',
        other_fiels => "they doesn't matter"
    },
};

my $mocked_datadog = Test::MockModule->new('DataDog::DogStatsd::Helper');
my @datadog_args;
$mocked_datadog->redefine('stats_inc', sub { @datadog_args = @_ });

subtest 'Acquired sent events' => sub {
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

subtest 'Unsupported provider' => sub {
    my $action_handler = BOM::Event::Process::get_action_mappings()->{dispute_notification};
    my @emails_sent;

    BOM::Test::Email::mailbox_clear();
    @emails_sent = BOM::Test::Email::email_list();
    is scalar @emails_sent, 0, 'Intially no e-mail was sent';

    $action_handler->($unsupported_provider);
    is $datadog_args[0], "event.dispute_notification.unsupported_provider.acquire_clearly_wrong", 'Stats for unsuppoted provider are increased';

    @emails_sent = BOM::Test::Email::email_list();

    is scalar @emails_sent, 0, 'No e-mail sent';
};

subtest 'Unsupported acquired event' => sub {
    my $action_handler = BOM::Event::Process::get_action_mappings()->{dispute_notification};
    my @emails_sent;

    BOM::Test::Email::mailbox_clear();
    @emails_sent = BOM::Test::Email::email_list();
    is scalar @emails_sent, 0, 'Intially no e-mail was sent';

    lives_ok { $action_handler->($unsupported_acquired_event) } "Sub don't dies on unsupported event";

    is $datadog_args[0], "event.dispute_notification.acquired.unsupported." . $unsupported_acquired_event->{data}->{event},
        'Stat for acquired.com unsupported event is increased';

    @emails_sent = BOM::Test::Email::email_list();

    is scalar @emails_sent, 0, 'No e-mail sent';
};
done_testing();
