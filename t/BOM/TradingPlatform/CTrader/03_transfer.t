use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates);
use JSON::MaybeUTF8;
use BOM::Rules::Engine;
use BOM::TradingPlatform;
use BOM::Config::Runtime;
use Data::Dump 'pp';

my $ctconfig       = BOM::Config::Runtime->instance->app_config->system->ctrader;
my $mocked_ctrader = Test::MockModule->new('BOM::TradingPlatform::CTrader');
my $mock_apidata   = {
    ctid_create                 => {userId => 1001},
    ctid_getuserid              => {userId => 1001},
    ctradermanager_getgrouplist => [{name => 'ctrader_all_svg_std_usd', groupId => 1}],
    trader_create               => {
        login                 => 100001,
        groupName             => 'ctrader_all_svg_std_usd',
        registrationTimestamp => 123456,
        depositCurrency       => 'USD',
        balance               => 0,
        moneyDigits           => 2
    },
    trader_get => {
        login                 => 100001,
        groupName             => 'ctrader_all_svg_std_usd',
        registrationTimestamp => 123456,
        depositCurrency       => 'USD',
        balance               => 0,
        moneyDigits           => 2
    },
    tradermanager_gettraderlightlist => [{traderId => 1001, login => 100001}],
    ctid_linktrader                  => {ctidTraderAccountId => 1001},
    tradermanager_deposit            => {balanceHistoryId    => 1},
    tradermanager_withdraw           => {balanceHistoryId    => 1}};

my %ctrader_mock = (
    call_api => sub {
        $mocked_ctrader->mock(
            'call_api',
            shift // sub {
                my ($self, %payload) = @_;
                my $method         = $payload{method};
                my $trader_balance = $mock_apidata->{trader_get}->{balance};
                $mock_apidata->{trader_get}->{balance} = $trader_balance + $payload{payload}->{amount} if $method eq 'tradermanager_deposit';

                if ($method eq 'tradermanager_withdraw') {
                    if ($trader_balance - $payload{payload}->{amount} >= 0) {
                        $mock_apidata->{trader_get}->{balance} = $trader_balance - $payload{payload}->{amount};
                    } else {
                        return {errorCode => 'NOT_ENOUGH_MONEY'};
                    }
                }

                return $mock_apidata->{$method};
            });
    },
);

$ctrader_mock{call_api}->();

my $mock_fees = Test::MockModule->new('BOM::Config::CurrencyConfig', no_auto => 1);
$mock_fees->mock(
    transfer_between_accounts_fees => sub {
        return {
            'USD' => {'AUD' => 10},
            'AUD' => {'USD' => 15}};
    });

populate_exchange_rates({AUD => 0.75});

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
$client->email('ctradertransfer@test.com');
my $user = BOM::User->create(
    email    => $client->email,
    password => 'test'
);
$user->add_client($client);
$client->set_default_account('AUD');
$client->binary_user_id($user->id);
$client->save;

BOM::Test::Helper::Client::top_up($client, $client->currency, 100);

my $ctrader = BOM::TradingPlatform->new(
    platform    => 'ctrader',
    client      => $client,
    user        => $user,
    rule_engine => BOM::Rules::Engine->new(
        client => $client,
        user   => $user
    ));

my $account = $ctrader->new_account(
    account_type => "real",
    market_type  => "all",
    platform     => "ctrader"
);

my $ctbalance;

subtest 'deposits' => sub {
    cmp_deeply(exception { $ctrader->deposit(amount => 10, to_account => 'xxx') }, {error_code => 'CTraderInvalidAccount'}, 'invalid account');
    cmp_deeply(
        exception { $ctrader->deposit(amount => 10, to_account => $account->{account_id}, currency => 'JPY') },
        {
            error_code => 'CurrencyShouldMatch',
            rule       => 'transfers.currency_should_match'
        },
        'invalid currency'
    );

    my %params = (
        to_account => $account->{account_id},
        amount     => 10,
        currency   => 'AUD',
    );

    $ctconfig->suspend->deposits(1);
    cmp_deeply(exception { $ctrader->deposit(%params) }, {error_code => 'CTraderDepositSuspended'}, 'error when deposits suspended');
    $ctconfig->suspend->deposits(0);

    $ctconfig->suspend->all(1);
    cmp_deeply(exception { $ctrader->deposit(%params) }, {error_code => 'CTraderSuspended'}, 'error when all suspended');
    $ctconfig->suspend->all(0);

    $ctconfig->suspend->real(1);
    cmp_deeply(exception { $ctrader->deposit(%params) }, {error_code => 'CTraderServerSuspended'}, 'error when real suspended');
    $ctconfig->suspend->real(0);
    $ctconfig->suspend->demo(1);

    my $dep;
    is(exception { $dep = $ctrader->deposit(%params) }, undef, 'no error when demo suspended');

    is $client->user->daily_transfer_count(
        type       => 'ctrader',
        identifier => $user->id
        ),
        1, 'Daily transfer counter increased';

    my $fee = 10 * 0.15;
    $ctbalance = sprintf("%.2f", (10 - $fee) * 0.75);

    cmp_deeply(
        $dep,
        {
            transaction_id        => re('^\d+$'),
            balance               => num($ctbalance),
            display_balance       => $ctbalance,
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

    cmp_ok $client->account->balance,              '==', 90,         'client balance decreased';
    cmp_ok $ctrader->get_accounts->[0]->{balance}, '==', $ctbalance, 'ctrader account balance increased';

    my ($details) = $client->db->dbic->dbh->selectrow_array('select details from transaction.transaction_details where transaction_id = ?',
        undef, $dep->{transaction_id});

    cmp_deeply(
        JSON::MaybeUTF8::decode_json_utf8($details),
        {
            ctrader_account_id        => $account->{account_id},
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
                'select ctrader_account_id, ctrader_amount from payment.ctrader_transfer d
                join transaction.transaction t on t.payment_id = d.payment_id where t.id = ?',
                undef, $dep->{transaction_id})
        ],
        [
            $account->{account_id},
            $ctbalance
        ],
        'ctrader_transfer table entry'
    );

};

subtest 'withdrawal' => sub {
    cmp_deeply(
        exception { $ctrader->withdraw(amount => $ctbalance, from_account => 'xxx') },
        {error_code => 'CTraderInvalidAccount'},
        'invalid account'
    );

    cmp_deeply(
        exception { $ctrader->withdraw(amount => $ctbalance + 1, from_account => $account->{account_id}) },
        {error_code => 'CTraderInsufficientBalance'},
        'excessive amount'
    );

    my %params = (
        from_account => $account->{account_id},
        amount       => $ctbalance,
    );

    $ctconfig->suspend->withdrawals(1);
    cmp_deeply(exception { $ctrader->withdraw(%params) }, {error_code => 'CTraderWithdrawalSuspended'}, 'error when withdrawal suspended');
    $ctconfig->suspend->withdrawals(0);

    $ctconfig->suspend->all(1);
    cmp_deeply(exception { $ctrader->withdraw(%params) }, {error_code => 'CTraderSuspended'}, 'error when all suspended');
    $ctconfig->suspend->all(0);

    $ctconfig->suspend->real(1);
    cmp_deeply(exception { $ctrader->withdraw(%params) }, {error_code => 'CTraderServerSuspended'}, 'error when real suspended');
    $ctconfig->suspend->real(0);
    $ctconfig->suspend->demo(1);

    my $wd;
    is(exception { $wd = $ctrader->withdraw(%params) }, undef, 'can withdraw when demo server is suspended');

    my $fee      = $ctbalance * 0.1;
    my $localbal = sprintf("%.2f", ($ctbalance - $fee) * (1 / 0.75));

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

    is $client->user->daily_transfer_count(
        type       => 'ctrader',
        identifier => $user->id
        ),
        2, 'Daily transfer counter increased';

    cmp_ok $ctrader->get_accounts->[0]->{balance}, '==', 0,              'ctrader account balance decreased';
    cmp_ok $client->account->balance,              '==', 90 + $localbal, 'client balance increased';

    my ($details) = $client->db->dbic->dbh->selectrow_array('select details from transaction.transaction_details where transaction_id = ?',
        undef, $wd->{transaction_id});

    cmp_deeply(
        JSON::MaybeUTF8::decode_json_utf8($details),
        {
            ctrader_account_id        => $account->{account_id},
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
                'select ctrader_account_id, ctrader_amount from payment.ctrader_transfer d
                join transaction.transaction t on t.payment_id = d.payment_id where t.id = ?',
                undef, $wd->{transaction_id})
        ],
        [
            $account->{account_id},
            -$ctbalance
        ],
        'ctrader_transfer table entry'
    );
};

done_testing();
