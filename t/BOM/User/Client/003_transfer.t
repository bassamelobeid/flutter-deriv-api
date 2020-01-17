use strict;
use warnings;
use Test::More;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );
use BOM::Test::Helper::ExchangeRates qw( populate_exchange_rates_db );

my $emit_data;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(
    'emit',
    sub {
        my ($type, $data) = @_;
        $emit_data->{$type}{count}++;
        $emit_data->{$type}{last} = $data;
    });

subtest intra_fx_transfer => sub {
    my $client_from  = create_client();
    my $from_account = $client_from->set_default_account('USD');
    my $client_to    = create_client();
    my $to_account   = $client_to->set_default_account('JPY');
    my $txn          = $client_from->payment_legacy_payment(
        currency     => 'USD',
        amount       => 100,
        payment_type => 'ewallet',
        remark       => 'test',
        staff        => 'test'
    );
    cmp_ok($from_account->balance * 1, '==', 100, 'Account Balance Correct');
    isa_ok $txn, 'BOM::User::Client::PaymentTransaction', 'Correct trasaction object type';

    _test_events_prepare();

    $client_from->payment_account_transfer(
        inter_db_transfer => 1,
        toClient          => $client_to,
        currency          => 'USD',
        amount            => 100,
        to_amount         => 11236,
        fees              => 0
    );

    _test_events($client_from, $client_to);

    # 0.0089  USD/JPY rate set manually
    # set by populate_exchange_rates_db
    cmp_ok($to_account->balance, '==', 11236, 'Converted Amount Correct');
};

subtest intra_nofx_transfer => sub {
    my $client_usd1 = create_client();
    $client_usd1->set_default_account('USD');
    my $client_usd2 = create_client();
    $client_usd2->set_default_account('USD');

    $client_usd1->payment_legacy_payment(
        currency     => 'USD',
        amount       => 101,
        payment_type => 'ewallet',
        remark       => 'test',
        staff        => 'test'
    );

    _test_events_prepare();

    $client_usd1->payment_account_transfer(
        inter_db_transfer => 1,
        toClient          => $client_usd2,
        currency          => 'USD',
        amount            => 100,
        fees              => 0
    );

    _test_events(
        $client_usd1,
        $client_usd2,
        (
            to_currency => 'USD',
            to_amount   => '100.00'
        ));

    cmp_ok($client_usd2->default_account->balance, '==', 100, 'Currency not converted');
};

#transfer within same landing company
subtest fx_transfer => sub {
    my $client_from = create_client();
    populate_exchange_rates_db($client_from->db->dbic);
    my $from_account = $client_from->set_default_account('USD');
    my $client_to    = create_client();
    my $to_account   = $client_to->set_default_account('JPY');
    $client_from->payment_legacy_payment(
        currency     => 'USD',
        amount       => 100,
        payment_type => 'ewallet',
        remark       => 'test',
        staff        => 'test'
    );
    cmp_ok($from_account->balance * 1, '==', 100, 'Account Balance Correct');

    _test_events_prepare();

    my $transaction_id = $client_from->payment_account_transfer(
        toClient  => $client_to,
        currency  => 'USD',
        amount    => 100,
        to_amount => 11124,
        fees      => 1
    );

    _test_events(
        $client_from,
        $client_to,
        (
            to_amount => '11124.00',
            fees      => 1
        ));

    # 0.0089  USD/JPY rate in regentmarkets_test/data_collection.exchange_rate
    # set by populate_exchange_rates_db

    # (100USD - 1% fees) / .0089 = 11124 (JPY rounded to whole numbers)
    cmp_ok($to_account->balance, '==', 11124, 'Converted Amount with fees Correct');
    my $payment = _get_payment_from_transaction($client_to->db->dbic, $transaction_id->{transaction_id});
    is($payment->{transfer_fees}, 1, 'Correct Fee recorded');
};

sub _get_payment_from_transaction {
    my ($dbic, $transaction_id) = @_;

    my $result = $dbic->run(
        fixup => sub {
            $_->selectrow_hashref(
                "Select pp.* FROM payment.payment pp JOIN transaction.transaction tt
                ON pp.id = tt.payment_id where tt.id = ?",
                undef,
                $transaction_id,
            );
        });
    return $result;
}

sub _test_events_prepare {
    undef $emit_data;
}

sub _test_events {
    my ($client_from, $client_to, %optional) = @_;

    my $to_currency = $optional{to_currency} // 'JPY';
    my $to_amount   = $optional{to_amount}   // '11236.00';
    my $fees        = $optional{fees}        // 0;

    is $emit_data->{transfer_between_accounts}{count}, 1, "transfer_between_accounts event emitted only once";

    my $response = $emit_data->{transfer_between_accounts}{last};

    is_deeply(
        $response,
        {
            loginid    => $client_from->{loginid},
            properties => {
                fees               => $fees,
                from_account       => $client_from->{loginid},
                from_amount        => 100,
                from_currency      => "USD",
                gateway_code       => "account_transfer",
                source             => undef,
                to_account         => $client_to->{loginid},
                to_amount          => $to_amount,
                to_currency        => $to_currency,
                is_from_account_pa => 0,
                is_to_account_pa   => 0,
                time               => $response->{properties}->{time},
                id                 => $response->{properties}->{id},
            }
        },
        'transfer_between_accounts event provides data properly.'
    );
}

done_testing();
