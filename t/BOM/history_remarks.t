use strict;
use warnings;

use Test::More;
use Test::Deep;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User;
use BOM::Test::Helper::Token;
use BOM::Test::Helper::P2P;
use BOM::Transaction::History qw(get_transaction_history);
use BOM::TradingPlatform;
use BOM::Config::Runtime;

subtest 'doughflow' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'doughflow@binary.com'
    });

    BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);

    my %params = (
        currency => $client->currency,
        remark   => 'xxx',
    );

    $client->payment_doughflow(
        %params,
        amount         => 10,
        payment_fee    => 1,
        payment_method => 'MegaPay',
        trace_id       => 101
    );
    my @res = get_remarks($client);
    is $res[1], 'MegaPay trace ID 101',         'Deposit remark';
    is $res[0], 'Fee for MegaPay trace ID 101', 'Deposit fee remark';

    $client->payment_doughflow(
        %params,
        amount            => 10,
        payment_fee       => 1,
        payment_processor => 'UltraPay',
        trace_id          => 102
    );
    @res = get_remarks($client);
    is $res[1], 'UltraPay trace ID 102',         'Fall back to payment_processor';
    is $res[0], 'Fee for UltraPay trace ID 102', 'Fall back to payment_processor for fee';

    $client->payment_doughflow(
        %params,
        amount         => -10,
        payment_method => 'NicePay',
        trace_id       => 103
    );
    @res = get_remarks($client);
    is $res[0], 'NicePay trace ID 103', 'Withdrawal';

    $client->payment_doughflow(
        %params,
        transaction_type => 'withdrawal_reversal',
        amount           => 10,
        payment_fee      => -1,
        payment_method   => 'BigPay',
        trace_id         => 104
    );
    @res = get_remarks($client);
    is $res[1], 'Reversal of BigPay trace ID 104',         'Withdrawal reversal';
    is $res[0], 'Reversal of fee for BigPay trace ID 104', 'Fee reversal';
};

subtest 'crypto' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'crypto@binary.com'
    });
    $client->account('BTC');
    BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);

    $client->payment_ctc(
        currency         => $client->currency,
        amount           => 10,
        crypto_id        => 1,
        address          => 'address1',
        transaction_hash => 'txhash1',

    );

    $client->payment_ctc(
        currency         => $client->currency,
        amount           => -10,
        crypto_id        => 2,
        address          => 'address2',
        transaction_hash => '',
    );

    my @res = get_remarks($client);
    is $res[1], 'Address: address1, transaction: txhash1', 'Deposit remark';
    is $res[0], 'Address: address2',                       'Withdrawal remark';
};

subtest 'mt5 transfers' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'mt5@binary.com'
    });

    BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);

    my %params = (
        currency => $client->currency,
    );

    # setting of txn_details values is covered in bom-rpc/t/BOM/RPC/MT5/60_mt5_transfer.t
    my $txn = $client->payment_mt5_transfer(
        %params,
        remark      => 'blabla',
        amount      => 10,
        fees        => 1,
        txn_details => {
            mt5_account               => '101',
            fees                      => 1.1,
            fees_currency             => 'EUR',
            fees_percent              => 1.2,
            min_fee                   => 0.1,
            fee_calculated_by_percent => 1.1,
        },
    );
    my @res = get_remarks($client);
    is $res[0], 'Transfer from MT5 account 101. Includes transfer fee of 1.10 EUR (1.2%).', 'MT5 withdrawal with fee';

    $txn = $client->payment_mt5_transfer(
        %params,
        remark      => 'blabla',
        amount      => 10,
        txn_details => {
            mt5_account => '102',
            fees        => 0,
        },
    );
    @res = get_remarks($client);
    is $res[0], 'Transfer from MT5 account 102', 'MT5 withdrawal with no fee';

    $txn = $client->payment_mt5_transfer(
        %params,
        remark      => 'blabla',
        amount      => -8,
        fees        => 1,
        txn_details => {
            mt5_account               => '103',
            fees                      => 2,
            fees_currency             => 'USD',
            fees_percent              => 6,
            min_fee                   => 2,
            fee_calculated_by_percent => 1.1,
        },
    );
    @res = get_remarks($client);
    is $res[0], 'Transfer to MT5 account 103. Includes the minimum transfer fee of 2.00 USD.', 'MT5 deposit with min fee';

    $txn = $client->payment_mt5_transfer(
        %params,
        remark      => 'blabla.',
        amount      => -1.23,
        txn_details => {
            mt5_account => '104',
            fees        => 0,
        },
    );
    @res = get_remarks($client);
    is $res[0], 'Transfer to MT5 account 104', 'MT5 deposit with no fee';
};

subtest 'transfer between accounts' => sub {
    my $client_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'tba@binary.com'
    });
    $client_usd->account('USD');
    my $client_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $client_usd->email
    });
    $client_btc->account('BTC');
    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
        email       => $client_usd->email
    });
    $client_mf->account('USD');

    my $user = BOM::User->create(
        email    => $client_usd->email,
        password => 'test'
    );
    $user->add_client($client_usd);
    $user->add_client($client_btc);
    $user->add_client($client_mf);
    BOM::Test::Helper::Client::top_up($client_usd, $client_usd->currency, 1000);

    # setting of txn_details values is covered in bom-rpc/t/BOM/RPC/Cashier/20_transfer_between_accounts.t
    my $txn = $client_usd->payment_account_transfer(
        currency    => 'USD',
        amount      => 10,
        to_amount   => 1,
        toClient    => $client_btc,
        remark      => 'blabla',
        fees        => 1.1,
        txn_details => {
            from_login                => $client_usd->loginid,
            to_login                  => $client_btc->loginid,
            fees                      => 1.1,
            fees_currency             => 'USD',
            fees_percent              => 1.5,
            min_fee                   => 0.5,
            fee_calculated_by_percent => 1.1,
        },
    );

    my @res = get_remarks($client_usd);
    is $res[0], 'Account transfer to ' . $client_btc->loginid . '. Includes transfer fee of 1.10 USD (1.5%).', 'Transfer with fee';

    @res = get_remarks($client_btc);
    is $res[0], 'Account transfer from ' . $client_usd->loginid . '. Includes transfer fee of 1.10 USD (1.5%).', 'Transfer with fee';

    $txn = $client_usd->payment_account_transfer(
        currency    => 'USD',
        amount      => 5,
        to_amount   => 0.5,
        toClient    => $client_btc,
        remark      => 'blabla',
        fees        => 0,
        txn_details => {
            from_login => $client_usd->loginid,
            to_login   => $client_btc->loginid,
            fees       => 0,
        },
    );

    @res = get_remarks($client_usd);
    is $res[0], 'Account transfer to ' . $client_btc->loginid, 'Transfer with no fee';

    @res = get_remarks($client_btc);
    is $res[0], 'Account transfer from ' . $client_usd->loginid, 'Transfer with no fee';

    $txn = $client_btc->payment_account_transfer(
        currency    => 'BTC',
        amount      => 0.75,
        to_amount   => 75,
        toClient    => $client_usd,
        remark      => 'blabla',
        fees        => 2,
        txn_details => {
            from_login                => $client_btc->loginid,
            to_login                  => $client_usd->loginid,
            fees                      => 0.002,
            fees_currency             => 'BTC',
            fees_percent              => 1.23,
            min_fee                   => 0.002,
            fee_calculated_by_percent => 0.001,
        });

    @res = get_remarks($client_usd);
    is $res[0], 'Account transfer from ' . $client_btc->loginid . '. Includes the minimum transfer fee of 0.00200000 BTC.',
        'Transfer back with min fee';

    @res = get_remarks($client_btc);
    is $res[0], 'Account transfer to ' . $client_usd->loginid . '. Includes the minimum transfer fee of 0.00200000 BTC.',
        'Transfer back with min fee';

    $txn = $client_usd->payment_account_transfer(
        currency    => 'USD',
        amount      => 10,
        to_amount   => 10,
        toClient    => $client_mf,
        remark      => 'blabla',
        fees        => 0.1,
        txn_details => {
            from_login                => $client_usd->loginid,
            to_login                  => $client_mf->loginid,
            fees                      => 0.01,
            fees_currency             => 'USD',
            fees_percent              => 0.9,
            min_fee                   => 0.01,
            fee_calculated_by_percent => 0.01,
        });

    @res = get_remarks($client_usd);
    is $res[0], 'Account transfer to ' . $client_mf->loginid . '. Includes transfer fee of 0.01 USD (0.9%).', 'Inter db transfer with fee';

    @res = get_remarks($client_mf);
    is $res[0], 'Account transfer from ' . $client_usd->loginid . '. Includes transfer fee of 0.01 USD (0.9%).', 'Inter db transfer with fee';

    $txn = $client_mf->payment_account_transfer(
        currency    => 'USD',
        amount      => 5,
        to_amount   => 0.01,
        toClient    => $client_btc,
        remark      => 'blabla',
        fees        => 0,
        txn_details => {
            from_login => $client_mf->loginid,
            to_login   => $client_btc->loginid,
            fees       => 0,
        });

    @res = get_remarks($client_mf);
    is $res[0], 'Account transfer to ' . $client_btc->loginid, 'Inter db transfer with no fee';

    @res = get_remarks($client_btc);
    is $res[0], 'Account transfer from ' . $client_mf->loginid, 'Inter db transfer with no fee';
};

subtest 'p2p' => sub {
    my $escrow = BOM::Test::Helper::P2P::create_escrow;
    BOM::Test::Helper::P2P::bypass_sendbird();

    my ($order, $advert, $result);

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(
        name    => 'andy',
        balance => 100
    );
    my $client = BOM::Test::Helper::P2P::create_advertiser(
        name    => 'cody',
        balance => 100
    );

    subtest 'sell ads' => sub {
        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
            client => $advertiser,
            type   => 'sell'
        );
        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            client    => $client,
            advert_id => $advert->{id},
            amount    => 10
        );

        my @res = get_remarks($advertiser);
        is $res[0], 'P2P order ' . $order->{id} . ' created by cody (' . $client->loginid . ') - seller funds held',
            'order create remark for advertiser';

        $client->p2p_order_confirm(id => $order->{id});
        $advertiser->p2p_order_confirm(id => $order->{id});

        @res = get_remarks($advertiser);
        is $res[1], 'P2P order ' . $order->{id} . ' completed - seller funds released', 'release remark for advertiser';
        is $res[0], 'P2P order ' . $order->{id} . ' completed - funds transferred to cody (' . $client->loginid . ')',
            'payment remark for advertiser';

        @res = get_remarks($client);
        is $res[0], 'P2P order ' . $order->{id} . ' completed - funds received from andy (' . $advertiser->loginid . ')', 'payment remark for client';

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            client    => $client,
            advert_id => $advert->{id},
            amount    => 10
        );
        $client->p2p_order_cancel(id => $order->{id});

        @res = get_remarks($advertiser);
        is $res[0], 'P2P order ' . $order->{id} . ' cancelled - seller funds released', 'cancel remark for advertiser';

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            client    => $client,
            advert_id => $advert->{id},
            amount    => 10
        );
        BOM::Test::Helper::P2P::expire_order($client, $order->{id});
        $client->p2p_expire_order(id => $order->{id});

        @res = get_remarks($advertiser);
        is $res[0], 'P2P order ' . $order->{id} . ' refunded - seller funds released', 'refund remark for advertiser';
    };

    subtest 'buy ads' => sub {
        ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
            client => $advertiser,
            type   => 'buy'
        );
        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            client    => $client,
            advert_id => $advert->{id},
            amount    => 10
        );

        my @res = get_remarks($client);
        is $res[0], 'P2P order ' . $order->{id} . ' created - seller funds held', 'order create remark for client';

        @res = get_remarks($escrow);
        is $res[0], 'P2P order ' . $order->{id} . ' created by cody (' . $client->loginid . ') - seller funds held', 'order create remark for escrow';

        $advertiser->p2p_order_confirm(id => $order->{id});
        $client->p2p_order_confirm(id => $order->{id});

        @res = get_remarks($client);
        is $res[1], 'P2P order ' . $order->{id} . ' completed - seller funds released', 'release remark for client';
        is $res[0], 'P2P order ' . $order->{id} . ' completed - funds transferred to andy (' . $advertiser->loginid . ')',
            'payment remark for client';

        @res = get_remarks($advertiser);
        is $res[0], 'P2P order ' . $order->{id} . ' completed - funds received from cody (' . $client->loginid . ')', 'payment remark for advertiser';

        ($client, $order) = BOM::Test::Helper::P2P::create_order(
            client    => $client,
            advert_id => $advert->{id},
            amount    => 10
        );
        $advertiser->p2p_order_cancel(id => $order->{id});

        @res = get_remarks($client);
        is $res[0], 'P2P order ' . $order->{id} . ' cancelled - seller funds released', 'cancel remark for client';
    };
};

subtest 'legacy transactions' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'legacy@binary.com'
    });

    BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);

    my %params = (
        currency => $client->currency,
    );

    my $txn = $client->payment_mt5_transfer(
        %params,
        remark => 'legacy remark',
        amount => 10,
    );

    my @res = get_remarks($client);
    is $res[0], 'legacy remark', 'legacy remark used when no transacation details';
};

subtest 'dxtrader' => sub {
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'dxtrade@binary.com'
    });
    $client->account('USD');

    my $dxtrader = BOM::TradingPlatform->new(
        platform => 'dxtrade',
        client   => $client
    );

    $dxtrader->client_payment(
        payment_type => 'dxtrade_transfer',
        amount       => 10,
        remark       => 'legacy remark',
        txn_details  => {
            dxtrade_account_id => 'DXD001',
            fees               => 0,
        },
    );

    my @res = get_remarks($client);
    is $res[0], 'Transfer from Deriv X account DXD001', 'withdrawal no fee';

    $dxtrader->client_payment(
        payment_type => 'dxtrade_transfer',
        amount       => 10,
        remark       => 'legacy remark',
        txn_details  => {
            dxtrade_account_id        => 'DXD002',
            fees                      => 1.23,
            fees_percent              => 10,
            fees_currency             => 'SGD',
            min_fee                   => 0.1,
            fee_calculated_by_percent => 1.23,
        },
    );

    @res = get_remarks($client);
    is $res[0], 'Transfer from Deriv X account DXD002. Includes transfer fee of 1.23 SGD (10%).', 'withdrawal with fee';

    $dxtrader->client_payment(
        payment_type => 'dxtrade_transfer',
        amount       => -5,
        remark       => 'legacy remark',
        txn_details  => {
            dxtrade_account_id => 'DXD003',
            fees               => 0,
        },
    );

    @res = get_remarks($client);
    is $res[0], 'Transfer to Deriv X account DXD003', 'deposit no fee';

    $dxtrader->client_payment(
        payment_type => 'dxtrade_transfer',
        amount       => -5,
        remark       => 'legacy remark',
        txn_details  => {
            dxtrade_account_id        => 'DXD004',
            fees                      => 0.9,
            fees_percent              => 1.5,
            fees_currency             => 'USD',
            min_fee                   => 0.1,
            fee_calculated_by_percent => 0.9,
        },
    );

    @res = get_remarks($client);
    is $res[0], 'Transfer to Deriv X account DXD004. Includes transfer fee of 0.90 USD (1.5%).', 'deposit with fee';
};

sub get_remarks {
    return map { $_->{payment_remark} } get_transaction_history({client => shift})->@*;
}

done_testing();
