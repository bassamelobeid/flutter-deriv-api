use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::MockTime qw(set_fixed_time);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Backoffice::PromoCodeEligibility;
use Date::Utility;
use BOM::Database::Helper::FinancialMarketBet;
use JSON::MaybeUTF8 qw(:v1);

my $client_db    = BOM::Database::ClientDB->new({broker_code => 'CR'})->db->dbic->dbh;
my $collector_db = BOM::Database::ClientDB->new({broker_code => 'FOG'})->db->dbic->dbh;

my %clients;

# clear out initial test db stuff
reset_promos();
$client_db->do("update betonmarkets.client set myaffiliates_token = NULL;");
$_->do("delete from betonmarkets.promo_code;") for ($client_db, $collector_db);

my $user1_email = 'promotest1@binary.com';

my $user1 = BOM::User->create(
    email    => $user1_email,
    password => 'test'
);

$clients{user1_c1} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code        => 'CR',
    email              => $user1_email,
    date_joined        => '2000-01-02',
    myaffiliates_token => 'token1',
    residence          => 'id',
    binary_user_id     => $user1->id,
});
$clients{user1_c1}->account('EUR');

$clients{user1_c2} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code        => 'CR',
    email              => $user1_email,
    date_joined        => '2000-01-02',
    myaffiliates_token => 'token1',
    residence          => 'id',
    binary_user_id     => $user1->id,
});
$clients{user1_c2}->account('BTC');

my $user2_email = 'promotest2@binary.com';

my $user2 = BOM::User->create(
    email    => $user2_email,
    password => 'test'
);

$clients{user2_c1} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code        => 'MF',
    email              => $user2_email,
    date_joined        => '2000-01-02',
    myaffiliates_token => 'token2',
    residence          => 'fi',
    binary_user_id     => $user2->id,
});
$clients{user2_c1}->account('USD');

$clients{user2_c2} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code        => 'MLT',
    email              => $user2_email,
    date_joined        => '2000-01-02',
    myaffiliates_token => 'token2',
    residence          => 'fi',
    binary_user_id     => $user2->id,
});
$clients{user2_c2}->account('USD');

my $user3_email = 'promotest3@binary.com';

my $user3 = BOM::User->create(
    email    => $user3_email,
    password => 'test'
);

$clients{user3_c1} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $user3_email,
    date_joined    => '2001-01-01',
    residence      => 'id',
    binary_user_id => $user3->id,
});
$clients{user3_c1}->account('USD');

for my $id (1..9) {
    my $email = 'generic' . $id . '@binary.com';
    my $user  = BOM::User->create(
        email    => $email,
        password => 'test'
    );
    $clients{'generic' . $id} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        date_joined    => '2000-01-01',
        residence      => 'id',
        binary_user_id => $user->id,
    });
    $clients{'generic' . $id}->account('USD');
}

my @promos = (
    ['PROMO1', 'FREE_BET',             '{"country":"ALL","amount":"10","currency":"ALL"}',                    '2000-01-01', '2000-02-01', 't'],
    ['PROMO2', 'FREE_BET',             '{"country":"za","amount":"10","currency":"EUR"}',                     '2000-01-01', '2000-02-01', 't'],
    ['PROMO3', 'FREE_BET',             '{"country":"af,id,za","amount":"10","currency":"EUR"}',               '2000-01-01', '2000-02-01', 't'],
    ['PROMO4', 'FREE_BET',             '{"country":"ALL","amount":"10","currency":"ALL"}',                    '2000-01-01', '2000-02-02', 't'],
    ['PROMO5', 'FREE_BET',             '{"country":"ALL","amount":"10","currency":"ALL"}',                    '2001-01-01', '2001-02-02', 't'],
    ['PROMO6', 'GET_X_WHEN_DEPOSIT_Y', '{"country":"ALL","currency":"ALL","min_deposit":"10","amount":"10"}', '2000-01-01', '2000-02-01', 't'],
    [
        'PROMO7', 'GET_X_WHEN_DEPOSIT_Y', '{"country":"ALL","currency":"ALL","min_deposit":"10","amount":"10","payment_processor":"NETeller"}',
        '2000-01-01', '2000-02-01', 't'
    ],
    ['PROMO8', 'GET_X_OF_DEPOSITS', '{"country":"ALL","currency":"ALL","amount":"10","payment_processor":"ALL"}',    '2000-01-01', '2000-02-01', 't'],
    ['PROMO9', 'GET_X_OF_DEPOSITS', '{"country":"ALL","currency":"ALL","amount":"10","payment_processor":"Skrill"}', '2000-01-01', '2000-02-01', 't'],
    [
        'PROMO10', 'GET_X_OF_DEPOSITS',
        '{"country":"ALL","currency":"ALL","amount":"10","payment_processor":"ALL","min_amount":"10","max_amount":"50"}',
        '2000-01-01', '2000-02-01', 't'
    ],
    ['PROMO11', 'GET_X_WHEN_DEPOSIT_Y', '{"country":"ALL","currency":"ALL","min_deposit":"1","amount":"15","min_turnover":"0.5","turnover_type":"deposit"}', '2000-01-01', '2000-02-01', 't'],
    ['PROMO12', 'GET_X_OF_DEPOSITS',    '{"country":"ALL","currency":"ALL","min_deposit":"1","amount":"10","min_turnover":"1","turnover_type":"deposit"}', '2000-01-01', '2000-02-01', 't'],       
);

for my $p (@promos) {
    my $sql =
          "insert into betonmarkets.promo_code (code, promo_code_type, promo_code_config, start_date, expiry_date, status, description) values ('"
        . (join "','", @$p)
        . "','');";
    $_->do($sql) for ($client_db, $collector_db);
}

set_fixed_time('2000-01-02', '%Y-%m-%d');

my %aff_promos;

my $mock_aff = Test::MockModule->new('BOM::MyAffiliates');
$mock_aff->mock(
    'decode_token',
    sub {
        note 'mocking decode_token';
        return {TOKEN => [map { {PREFIX => 'token' . $_, USER_ID => $_} } 1 .. 5]};
    },
    'get_users',
    sub {
        note 'mocking get_users';
        return {
            USER => [
                map { {
                        ID             => $_,
                        USER_VARIABLES => {
                            VARIABLE => [{
                                    NAME  => 'betonmarkets_promo_code',
                                    VALUE => ';' . (join ';', $aff_promos{$_}->@*) . ';'
                                }]}}
                } keys %aff_promos
            ]};
    });

subtest 'affiliate promo for all countries' => sub {
    %aff_promos = (
        1 => ['PROMO1'],
        2 => ['PROMO1']);
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('user1_c1')->{promotion_code}, 'PROMO1',   'Promo matches ALL country';
    is client_promo('user1_c1')->{status},         'APPROVAL', 'Welcome promo is approved';
    is client_promo('user1_c2'), undef, 'Crypto client has no promo';
    is client_promo('user2_c1')->{promotion_code}, 'PROMO1',   'MF account chosen for promo';
    is client_promo('user2_c1')->{status},         'APPROVAL', 'Welcome promo is approved';
    is client_promo('user2_c2'), undef, 'MLT account not chosen for promo';
};

subtest 'affiliate promo for select countries' => sub {
    reset_promos();
    $aff_promos{1} = ['PROMO2'];
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('user1_c1'), undef, 'Promo not eligible in country - fiat';
    is client_promo('user1_c2'), undef, 'Promo not eligible in country - crypto';
};

subtest 'multiple affiliate promos' => sub {
    reset_promos();
    $aff_promos{1} = ['PROMO1', 'PROMO4'];
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('user1_c1')->{promotion_code}, 'PROMO4',   'Promo will longest expiry is applied';
    is client_promo('user1_c1')->{status},         'APPROVAL', 'Welcome promo is approved';
    is client_promo('user1_c2'), undef, 'Crypto client has no promo';
};

subtest 'GET_X_WHEN_DEPOSIT_Y promo approval' => sub {
    reset_promos();
    %aff_promos = (
        1 => ['PROMO6'],
        2 => ['PROMO6']);
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('user1_c1')->{promotion_code}, 'PROMO6',    'Deposit promo applied';
    is client_promo('user1_c1')->{status},         'NOT_CLAIM', 'Deposit promo not approved';
    is client_promo('user1_c2'), undef, 'Crypto client has no promo';
    is client_promo('user2_c1')->{promotion_code}, 'PROMO6',    'Deposit promo applied';
    is client_promo('user2_c1')->{status},         'NOT_CLAIM', 'Deposit promo not approved';

    deposit($clients{user1_c1}, 5, 'NETeller');
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('user1_c1')->{promotion_code}, 'PROMO6',    'Deposit promo still applied';
    is client_promo('user1_c1')->{status},         'NOT_CLAIM', 'Deposit promo not approved';

    deposit($clients{user1_c1}, 100, 'NETeller');
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('user1_c1')->{promotion_code}, 'PROMO6',    'Deposit promo still applied';
    is client_promo('user1_c1')->{status},         'NOT_CLAIM', 'Deposit promo not approved';

    buy_contract($clients{user1_c1}, 5);
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('user1_c1')->{promotion_code}, 'PROMO6',    'Deposit promo still applied';
    is client_promo('user1_c1')->{status},         'NOT_CLAIM', 'Deposit promo not approved';

    buy_contract($clients{user1_c1}, 100);
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('user1_c1')->{status}, 'APPROVAL',  'Deposit promo approved when conditions met';
    is client_promo('user2_c1')->{status}, 'NOT_CLAIM', 'Other client not approved';

    # NETeller promo
    $clients{generic1}->promo_code('PROMO7');
    $clients{generic1}->save;
    deposit($clients{generic1}, 100, 'NETeller');
    buy_contract($clients{generic1}, 100);
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('generic1')->{status}, 'APPROVAL', 'Payment processor specific promo approved';

    $clients{generic2}->promo_code('PROMO7');
    $clients{generic2}->save;
    deposit($clients{generic1}, 100, 'Skrill');
    buy_contract($clients{generic1}, 100);
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('generic2')->{status}, 'NOT_CLAIM', 'But not if different payment processor used';
};

subtest 'GET_X_OF_DEPOSITS promo approval' => sub {
    $clients{generic3}->promo_code('PROMO8');
    $clients{generic3}->save;
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('generic3')->{status}, 'NOT_CLAIM', 'No deposits, not approved';

    deposit($clients{generic3}, 50, 'NETeller');
    deposit($clients{generic3}, 50, 'Skrill');
    buy_contract($clients{generic3}, 100);
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('generic3')->{status}, 'APPROVAL', 'Approved after mixed deposits';

    my ($bonus, $deposit) = BOM::Backoffice::PromoCodeEligibility::get_dynamic_bonus(
         db           => $clients{generic3}->db->dbic,
         account_id   => $clients{generic3}->account->id,
         code         => 'PROMO8',
         promo_config => decode_json_utf8($clients{generic3}->client_promo_code->promotion->promo_code_config),
    );
    is $deposit, 100, 'correct deposit amount';
    is $bonus, 10, 'bonus is 10% of deposit';
    
    # Skrill only promo
    $clients{generic4}->promo_code('PROMO9');
    $clients{generic4}->save;
    deposit($clients{generic4}, 100, 'NETeller');
    buy_contract($clients{generic4}, 100);
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('generic4')->{status}, 'NOT_CLAIM', 'No Skrill deposit, not approved';

    $clients{generic5}->promo_code('PROMO9');
    $clients{generic5}->save;
    deposit($clients{generic5}, 100, 'Skrill');
    buy_contract($clients{generic5}, 100);
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('generic5')->{status}, 'APPROVAL', 'Has Skrill deposit, approved';

    # 10% payout, min 10, max 50
    $clients{generic6}->promo_code('PROMO10');
    $clients{generic6}->save;
    deposit($clients{generic6}, 1000, 'NETeller');
    # required turnover should be 5x max payout
    buy_contract($clients{generic6}, 100);
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('generic6')->{status}, 'NOT_CLAIM', 'Not enough turnover';
    buy_contract($clients{generic6}, 150);
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('generic6')->{status}, 'APPROVAL', 'Turnover requirement is based on max payout';

    $clients{generic7}->promo_code('PROMO10');
    $clients{generic7}->save;
    # try to get $5 payout
    deposit($clients{generic7}, 50, 'NETeller');
    buy_contract($clients{generic7}, 50);
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('generic7')->{status}, 'NOT_CLAIM', 'Minimum not hit';
    # go for $10
    deposit($clients{generic7}, 50, 'NETeller');
    buy_contract($clients{generic7}, 50);
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('generic7')->{status}, 'APPROVAL', 'Minimum reached';
};

subtest 'Deposit turnover eligibility' => sub {
    # GET_X_WHEN_DEPOSIT_Y  turnover requirement: 0.5 x deposit
    $clients{generic8}->promo_code('PROMO11');
    $clients{generic8}->save;
    deposit($clients{generic8}, 50, 'NETeller');
    buy_contract($clients{generic8}, 20);
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('generic8')->{status}, 'NOT_CLAIM', 'Turnover not hit';
    buy_contract($clients{generic8}, 10);
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('generic8')->{status}, 'APPROVAL', 'Minimum reached';

    # GET_X_OF_DEPOSITS  turnover requirement: 1 x deposit
    $clients{generic9}->promo_code('PROMO12');
    $clients{generic9}->save;
    deposit($clients{generic9}, 50, 'NETeller');
    buy_contract($clients{generic9}, 40);
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('generic9')->{status}, 'NOT_CLAIM', 'Turnover not hit';
    buy_contract($clients{generic9}, 10);
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('generic9')->{status}, 'APPROVAL', 'Minimum reached';
};

subtest 'client join date' => sub {
    reset_promos();
    set_fixed_time('2001-01-01', '%Y-%m-%d');

    $clients{user3_c1}->promo_code('PROMO1');
    $clients{user3_c1}->save;
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('user3_c1')->{promotion_code}, 'PROMO1',    'Promo applied';
    is client_promo('user3_c1')->{status},         'NOT_CLAIM', 'Promo not approved';

    $clients{user3_c1}->promo_code('PROMO5');
    $clients{user3_c1}->save;
    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('user3_c1')->{promotion_code}, 'PROMO5',   'Promo applied';
    is client_promo('user3_c1')->{status},         'APPROVAL', 'Promo approved';
};

subtest 'double redemption' => sub {
    reset_promos();
    set_fixed_time('2000-01-01', '%Y-%m-%d');

    my $user4_email = 'promotest4@binary.com';

    my $user4 = BOM::User->create(
        email    => $user4_email,
        password => 'test'
    );

    $clients{user4_c1} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MLT',
        email          => $user4_email,
        date_joined    => '2000-01-01',
        residence      => 'id',
        binary_user_id => $user4->id,
    });
    $clients{user4_c1}->account('USD');
    $clients{user4_c1}->promo_code('PROMO1');
    $clients{user4_c1}->save;

    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('user4_c1')->{promotion_code}, 'PROMO1',   'Promo applied';
    is client_promo('user4_c1')->{status},         'APPROVAL', 'Promo approved';

    $clients{user4_c2} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MF',
        email          => $user4_email,
        date_joined    => '2000-01-02',
        residence      => 'id',
        binary_user_id => $user4->id,
    });
    $clients{user4_c2}->account('USD');
    $clients{user4_c2}->promo_code('PROMO1');
    $clients{user4_c2}->save;

    BOM::Backoffice::PromoCodeEligibility::approve_all();
    is client_promo('user4_c2')->{promotion_code}, 'PROMO1',    'Promo applied';
    is client_promo('user4_c2')->{status},         'NOT_CLAIM', 'Promo not approved because other account already approved';
};

done_testing;

sub client_promo {
    my $c = shift;
    $client_db->selectrow_hashref("select * from betonmarkets.client_promo_code where client_loginid = '" . $clients{$c}->loginid . "'");
}

sub reset_promos {
    $client_db->do("delete from betonmarkets.client_promo_code;");
    $_->client_promo_code(undef) for values %clients;
    %aff_promos = ();
}

sub deposit {
    my ($client, $amount, $pp) = @_;
    $client->account->add_payment_transaction({
        amount               => $amount,
        payment_gateway_code => 'doughflow',
        payment_type_code    => 'testing',
        status               => 'OK',
        staff_loginid        => 'test',
        remark               => "DoughFlow deposit trace_id=123456 created_by=INTERNET payment_processor=$pp transaction_id=123456",
        payment_time         => Date::Utility->new()->db_timestamp,
    });
}

sub buy_contract {
    my ($client, $price) = @_;
    my $now      = Date::Utility->new();
    my $duration = '15s';

    BOM::Database::Helper::FinancialMarketBet->new({
            account_data => {
                client_loginid => $client->loginid,
                currency_code  => $client->account->currency_code,
            },
            bet_data => {
                underlying_symbol => 'frxUSDJPY',
                duration          => $duration,
                payout_price      => $price,
                buy_price         => $price,
                remark            => 'Test Remark',
                purchase_time     => $now->db_timestamp,
                start_time        => $now->db_timestamp,
                expiry_time       => $now->plus_time_interval($duration)->db_timestamp,
                settlement_time   => $now->plus_time_interval($duration)->db_timestamp,
                is_expired        => 1,
                is_sold           => 0,
                bet_class         => 'higher_lower_bet',
                bet_type          => 'CALL',
                short_code        => ('CALL_R_50_' . $price . '_' . $now->epoch . '_' . $now->plus_time_interval($duration)->epoch . '_S0P_0'),
                relative_barrier  => 'S0P',
                quantity          => 1,
            },
            db => $client->db,
        })->buy_bet;

}
