use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::DevExperts;
use BOM::Test::Helper::Client;
use BOM::TradingPlatform;
use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates);
use JSON::MaybeUTF8;
use BOM::Config::Runtime;

BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

BOM::User->create(
    email    => $client->email,
    password => 'test'
)->add_client($client);

$client->account('AUD');
BOM::Test::Helper::Client::top_up($client, $client->currency, 10);

my $mock_fees = Test::MockModule->new('BOM::Config::CurrencyConfig', no_auto => 1);
$mock_fees->mock(
    transfer_between_accounts_fees => sub {
        return {
            'USD' => {'AUD' => 10},
            'AUD' => {'USD' => 15}};
    });

populate_exchange_rates({AUD => 0.75});

my $dxtrader = BOM::TradingPlatform->new(
    platform => 'dxtrade',
    client   => $client
);

my $account = $dxtrader->new_account(
    account_type => 'real',
    password     => 'test',
    currency     => 'USD',
    market_type  => 'financial',
);

my $dxbal;

subtest 'deposits' => sub {
    cmp_deeply(exception { $dxtrader->deposit(amount => 10, to_account => 'xxx') }, {error_code => 'DXInvalidAccount'}, 'invalid account');
    cmp_deeply(
        exception { $dxtrader->deposit(amount => 10, to_account => $account->{account_id}, currency => 'JPY') },
        {error_code => 'CurrencyShouldMatch'},
        'invalid currency'
    );

    my $dep = $dxtrader->deposit(
        to_account => $account->{account_id},
        amount     => 10,
        currency   => 'AUD',
    );

    is $client->user->daily_transfer_count('dxtrade'), 1, 'Daily transfer counter increased';

    my $fee = 10 * 0.15;
    $dxbal = sprintf("%.2f", (10 - $fee) * 0.75);    # fee is deducted from source

    cmp_deeply(
        $dep,
        {
            transaction_id        => re('^\d+$'),
            balance               => num($dxbal),
            display_balance       => $dxbal,
            account_id            => $account->{account_id},
            account_type          => $account->{account_type},
            currency              => $account->{currency},
            login                 => $account->{login},
            platform              => $account->{platform},
            market_type           => $account->{market_type},
            landing_company_short => $account->{landing_company_short},
        },
        'expected result fields'
    );

    cmp_ok $client->account->balance, '==', 0, 'client balance decreased';
    cmp_ok $dxtrader->get_accounts->[0]->{balance}, '==', $dxbal, 'dxtrade account balance increased';

    my ($details) = $client->db->dbic->dbh->selectrow_array('select details from transaction.transaction_details where transaction_id = ?',
        undef, $dep->{transaction_id});

    cmp_deeply(
        JSON::MaybeUTF8::decode_json_utf8($details),
        {
            dxtrade_account_id        => $account->{account_id},
            fee_calculated_by_percent => num($fee),
            fees                      => num($fee),
            fees_currency             => $client->account->currency_code,
            fees_percent              => num(15),
            min_fee                   => ignore(),
        },
        'transaction_details table entry'
    );

    cmp_deeply([
            $client->db->dbic->dbh->selectrow_array(
                'select dxtrade_account_id, dxtrade_amount from payment.dxtrade_transfer d
                join transaction.transaction t on t.payment_id = d.payment_id where t.id = ?',
                undef, $dep->{transaction_id})
        ],
        [
            $account->{account_id},
            $dxbal
        ],
        'dxtrade_transfer table entry'
    );
};

subtest 'withdrawals' => sub {

    cmp_deeply(exception { $dxtrader->withdraw(amount => $dxbal, from_account => 'xxx') }, {error_code => 'DXInvalidAccount'}, 'invalid account');

    cmp_deeply(
        exception { $dxtrader->withdraw(amount => $dxbal + 1, from_account => $account->{account_id}) },
        {error_code => 'DXInsufficientBalance'},
        'excessive amount'
    );

    my $wd = $dxtrader->withdraw(
        from_account => $account->{account_id},
        amount       => $dxbal
    );

    my $fee      = $dxbal * 0.1;
    my $localbal = sprintf("%.2f", ($dxbal - $fee) * (1 / 0.75));

    cmp_deeply(
        $wd,
        {
            transaction_id        => re('^\d+$'),
            balance               => num(0),
            display_balance       => '0.00',
            account_id            => $account->{account_id},
            account_type          => $account->{account_type},
            currency              => $account->{currency},
            login                 => $account->{login},
            platform              => $account->{platform},
            market_type           => $account->{market_type},
            landing_company_short => $account->{landing_company_short},
        },
        'expected result fields'
    );

    is $client->user->daily_transfer_count('dxtrade'), 2, 'Daily transfer counter increased';
    cmp_ok $dxtrader->get_accounts->[0]->{balance}, '==', 0, 'dxtrade account balance decreased';
    cmp_ok $client->account->balance, '==', $localbal, 'client balance increased';

    my ($details) = $client->db->dbic->dbh->selectrow_array('select details from transaction.transaction_details where transaction_id = ?',
        undef, $wd->{transaction_id});

    cmp_deeply(
        JSON::MaybeUTF8::decode_json_utf8($details),
        {
            dxtrade_account_id        => $account->{account_id},
            fee_calculated_by_percent => num($fee),
            fees                      => num($fee),
            fees_currency             => $account->{currency},
            fees_percent              => num(10),
            min_fee                   => ignore(),
        },
        'transaction_details table entry'
    );

    cmp_deeply([
            $client->db->dbic->dbh->selectrow_array(
                'select dxtrade_account_id, dxtrade_amount from payment.dxtrade_transfer d
                join transaction.transaction t on t.payment_id = d.payment_id where t.id = ?',
                undef, $wd->{transaction_id})
        ],
        [
            $account->{account_id},
            -$dxbal
        ],
        'dxtrade_transfer table entry'
    );
};

done_testing();
