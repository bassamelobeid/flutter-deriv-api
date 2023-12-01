use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;

use Object::Pad;
use BOM::Database::UserDB;
use BOM::MT5::User::Async;
use Date::Utility;
use BOM::Config;
use BOM::User;
use List::Util qw(min max);
use Syntax::Keyword::Try;
use BOM::Platform::Event::Emitter;
use Brands;
use JSON::MaybeXS                    qw(decode_json);
use ExchangeRates::CurrencyConverter qw(convert_currency);
use Format::Util::Numbers            qw(financialrounding);
use IO::Async::Loop;

use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::MT5::Script::StatusUpdate;

use Future;
use Future::AsyncAwait;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User::Client;
use BOM::User::Client::Account;
use constant RETRY_LIMIT => 5;

use JSON::MaybeXS qw(decode_json encode_json);
use Data::Dumper;

use constant SECOND_REMINDER_EMAIL_DAYS => 20;
use constant FIRST_REMINDER_EMAIL_DAYS  => 10;
use constant BVI_EXPIRATION_DAYS        => 10;
use constant BVI_WARNING_DAYS           => 8;
use constant VANUATU_EXPIRATION_DAYS    => 5;
use constant VANUATU_WARNING_DAYS       => 3;

my $bvi_group_attributes = encode_json({
    group           => 'real\p01_ts01\financial\bvi_std_usd',
    currency        => "USD",
    leverage        => 1000,
    market_type     => "financial",
    account_type    => "real",
    landing_company => "svg"
});

my $vanuatu_group_attributes = encode_json({
    group           => 'real\p01_ts01\financial\vanuatu_std_usd',
    currency        => "USD",
    leverage        => 1000,
    market_type     => "financial",
    account_type    => "real",
    landing_company => "svg"
});

my $svg_group_attributes = encode_json({
    group           => 'real\p01_ts01\financial\svg_std_usd',
    currency        => "USD",
    leverage        => 1000,
    market_type     => "financial",
    account_type    => "real",
    landing_company => "svg"
});

my $creation_stamp = Date::Utility->new('2022-10-24 1000');

my @test_pending_users = (
    ['MTR100000001', '10000001', $creation_stamp->db_timestamp, 'poa_pending', 'mt5', 'real', 'USD', $bvi_group_attributes],
    [
        'MTR100000002', '10000002', $creation_stamp->minus_time_interval('1d')->db_timestamp, 'poa_pending', 'mt5', 'real', 'USD',
        $bvi_group_attributes
    ],
    [
        'MTR100000003', '10000003', $creation_stamp->minus_time_interval('2d')->db_timestamp,
        'poa_rejected', 'mt5', 'real', 'USD', $bvi_group_attributes
    ],
    ['MTR100000004', '10000004', $creation_stamp->db_timestamp, 'poa_outdated', 'mt5', 'real', 'USD', $bvi_group_attributes],
    [
        'MTR100000005', '10000005', $creation_stamp->minus_time_interval('2d')->db_timestamp,
        'poa_outdated', 'mt5', 'real', 'USD', $bvi_group_attributes
    ],
    [
        'MTR100000006', '10000006', $creation_stamp->minus_time_interval('2d')->db_timestamp,
        'poa_outdated', 'mt5', 'real', 'USD', $svg_group_attributes
    ],
);

my $status_update_mock = Test::MockModule->new('BOM::MT5::Script::StatusUpdate');
my $date_mock          = Test::MockModule->new('Date::Utility');
my $client_mock        = Test::MockModule->new('BOM::User::Client');
my $emitter_mock       = Test::MockModule->new('BOM::MT5::User::Async');
my $currency_mock      = Test::MockModule->new('ExchangeRates::CurrencyConverter');

# Returns 2022-11-3 12:45
$date_mock->mock(
    'today',
    sub {
        return Date::Utility->new('2022-11-3 1245');
    });

subtest 'grace_period_actions' => sub {

# Setup a test user
    my $test_client = create_client('CR');
    $test_client->email('test@test.ts');
    $test_client->set_default_account('USD');
    $test_client->binary_user_id(1);
    $test_client->save;

    my $password = 's3kr1t';
    my $hash_pwd = BOM::User::Password::hashpw($password);
    my $user     = BOM::User->create(
        email    => 'test@test.ts',
        password => $hash_pwd,
    );
    $user->update_trading_password($password);
    $user->add_client($test_client);

    my %restricted_loginids;
    my $restricted_clients = 0;
    my $users_loaded       = 0;

    $status_update_mock->redefine(
        'gather_users',
        sub {
            return @test_pending_users;
        }
    )->redefine(
        'restrict_client_and_send_email',
        async sub {
            my $params = $_[1];
            $restricted_loginids{$params->{loginid}} = 1;
            $restricted_clients++;
        }
    )->redefine(
        'load_all_user_data',
        sub {
            $users_loaded++;

            my $params = shift;
            return +{
                client      => $test_client,
                user        => $user,
                cr_currency => 'USD',
                bom_loginid => $test_client->loginid
            };
        });

    $client_mock->redefine(
        'get_poa_status',
        sub {
            return 'pending';
        });

    my $verification_status = BOM::MT5::Script::StatusUpdate->new;
    $verification_status->grace_period_actions;

    is $users_loaded,       6, 'correct number of clients loaded';
    is $restricted_clients, 3, 'correct number restrictions';

    cmp_deeply(
        \%restricted_loginids,
        {
            MTR100000002 => 1,
            MTR100000003 => 1,
            MTR100000005 => 1,
        },
        'expected restricted loginids'
    );

    $client_mock->mock(
        'get_poa_status',
        sub {
            return 'verified';
        });

    my $status_params;
    # rare case if status is verified but not displayed in db
    $status_update_mock->redefine(
        'gather_users',
        sub {
            my @clients;
            push @clients, ['MTR100000007', '10000007', $creation_stamp->db_timestamp, 'poa_pending', 'mt5', 'real', 'USD', $bvi_group_attributes];
            return @clients;
        }
    )->redefine(
        'update_loginid_status',
        sub {
            $status_params = $_[1];
            return 1;
        });

    $verification_status->grace_period_actions;
    is $status_params->{loginid},        'MTR100000007', 'correct loginid to clear status';
    is $status_params->{binary_user_id}, '10000007',     'correct binary_user_id to clear status';
    is $status_params->{to_status},      undef,          'status should be undef to clear it from db';

    $status_update_mock->unmock_all();
    $client_mock->unmock_all();

};

subtest 'restrict_client_and_send_email' => async sub {

    my %color_changed_loginids;
    my $status_params;
    my $email_params;
    my $email_triggered = 0;

    $status_update_mock->redefine(
        'send_email_to_client',
        sub {
            $email_triggered = 1;
            $email_params    = $_[1];
            return 1;
        }
    )->redefine(
        'change_account_color',
        sub {
            my $params = $_[1];
            $color_changed_loginids{$params->{loginid}} = 1;
            return 0;
        }
    )->redefine(
        'get_mt5_accounts_under_same_jurisdiction',
        sub {
            return 'MTR10010100';
        }
    )->redefine(
        'update_loginid_status',
        sub {
            $status_params = $_[1];
            return 1;
        });

    my $verification_status = BOM::MT5::Script::StatusUpdate->new;
    is $verification_status->restrict_client_and_send_email({
            group          => 'real\p01_ts01\financial\vanuatu_std_usd',
            loginid        => 'MTR10010100',
            binary_user_id => '999999',
            bom_loginid    => 'CR00000001'
        }
        ),
        0, 'returns 0 because had some fails';

    is $color_changed_loginids{'MTR10010100'}, 1,             'correct loginid to change the color';
    is $status_params->{binary_user_id},       '999999',      'got correct binary_user_id';
    is $status_params->{to_status},            'poa_failed',  'got correct status';
    is $status_params->{loginid},              'MTR10010100', 'got correct loginid';
    is $email_triggered ,                      0,             'email shouldnt be triggered';

    # correct result
    $status_update_mock->redefine(
        'update_loginid_status',
        sub {
            return 1;
        }
    )->redefine(
        'change_account_color',
        sub {
            return 1;
        }
    )->redefine(
        'get_mt5_accounts_under_same_jurisdiction',
        sub {
            return ('MTR10010100', 'MTR10010101');
        }
    )->redefine(
        'check_for_verified_poa_and_update_status',
        sub {
            return 0;
        });

    ok $verification_status->restrict_client_and_send_email({
            group       => 'real\p01_ts01\financial\vanuatu_std_usd',
            loginid     => 'MTR10010100',
            bom_loginid => 'CR00000001'
        }
        ),
        'changed color and status successfully';

    ok $email_triggered , 'email should trigger';
    is $email_params->{email_type},              'poa_verification_expired', 'correct email type';
    is $email_params->{email_params}->{loginid}, 'CR00000001',               'correct loginid in email';

    $status_update_mock->unmock_all();

};

subtest 'disable_users_actions' => async sub {

    my $test_client = create_client('CR');
    my $params;
    $test_client->email('test@test.ts');
    $test_client->set_default_account('USD');
    $test_client->binary_user_id(1);
    $test_client->save;

    my $password = 's3kr1t';
    my $hash_pwd = BOM::User::Password::hashpw($password);

    my $gather_params;
    $status_update_mock->redefine(
        'gather_users',
        sub {
            $gather_params = $_[1];
            return ([
                'MTR100000007', '10000007', Date::Utility->new('2022-09-24 1000')->db_timestamp,
                'poa_pending',  'mt5', 'real', 'USD', $bvi_group_attributes
            ]);
        }
    )->redefine(
        'load_all_user_data',
        sub {
            return +{
                client      => $test_client,
                user        => 1,
                cr_currency => 'EUR',
                bom_loginid => $test_client->loginid
            };
        }
    )->redefine(
        'check_activity_and_process_client',
        async sub {
            $params = $_[1];
        }
    )->redefine(
        'check_for_verified_poa_and_update_status',
        sub {
            return 0;
        });

    my $verification_status = BOM::MT5::Script::StatusUpdate->new;
    $verification_status->disable_users_actions;

    is $params->{loginid},        'MTR100000007',                        'correct loginid parameter passed';
    is $params->{cr_currency},    'EUR',                                 'correct cr_currency parameter passed';
    is $params->{group},          'real\p01_ts01\financial\bvi_std_usd', 'correct group parameter passed';
    is $params->{bom_loginid},    $test_client->loginid,                 'correct bom_loginid parameter passed';
    is $params->{binary_user_id}, '10000007',                            'correct binary_user_id parameter passed';
    ok $params->{user}, 'user parameter passed';

    is ref($gather_params), 'HASH', 'parameters passed to gather_users';
    if (ref($gather_params) eq 'HASH') {
        ok $gather_params->{newest_created_at}, 'date passed';
        ok $gather_params->{statuses},          'statuses passed';
    }

    $status_update_mock->unmock_all;

};

subtest 'check_activity_and_process_client' => async sub {

    $emitter_mock->mock(
        'get_open_orders_count',
        sub {
            return Future->done({total => 0});
        }
    )->mock(
        'get_open_positions_count',
        sub {
            return Future->done({total => 0});
        });

    $status_update_mock->redefine(
        'withdraw_and_archive',
        async sub {
            return +{result => 1};
        });

    my $verification_status = BOM::MT5::Script::StatusUpdate->new;
    my $response            = await $verification_status->check_activity_and_process_client({loginid => 'MTR1000001'});
    is ref $response, 'HASH', 'response should be a hashref';
    if (ref $response eq 'HASH') {
        is $response->{result}, 1, 'result okay';
    }

    $emitter_mock->mock(
        'get_open_positions_count',
        sub {
            return Future->done({total => 1});
        });

    $response = await $verification_status->check_activity_and_process_client({loginid => 'MTR1000001'});
    is ref $response, 'HASH', 'response should be a hashref';
    if (ref $response eq 'HASH') {
        is $response->{send_to_compops}, 1, 'dont archive and send email to compops';
    }

    $status_update_mock->unmock_all;

};

subtest 'withdraw_and_archive' => async sub {

    my $mt5_balance = 1000;
    my $params;

    # Setup a test user
    my $test_client = create_client('CR');
    $test_client->email('test@test.ts');
    $test_client->set_default_account('EUR');
    $test_client->binary_user_id(1);
    $test_client->save;

    $params->{loginid}        = 'MTR1000001';
    $params->{cr_currency}    = 'EUR';
    $params->{group}          = 'real\p01_ts01\financial\vanuatu_std_usd';
    $params->{user}           = 1;
    $params->{bom_loginid}    = 'CR1000001';
    $params->{binary_user_id} = '1000001';
    $params->{client}         = $test_client;
    my $withdrawal_amount;

    $emitter_mock->mock(
        'get_user',
        sub {
            return Future->done({balance => $mt5_balance});
        }
    )->mock(
        'get_group',
        sub {
            return Future->done({currency => 'USD'});
        }
    )->mock(
        'withdrawal',
        sub {
            $withdrawal_amount = shift;
            return Future->done({status => 1});
        }
    )->mock(
        'user_archive',
        sub {
            return Future->done({status => 1});
        });

    my $update_status_params;

    $currency_mock->redefine(
        'in_usd',
        sub {
            my $price         = shift;
            my $from_currency = shift;
            return $price;
        });

    my %client_args;
    $client_mock->mock(
        'payment_mt5_transfer',
        sub {
            my $self;
            ($self, %client_args) = @_;
        }
    )->mock(
        'payment_id',
        sub {
            return '777';
        });

    my $record_transfer_params;
    $status_update_mock->redefine(
        'update_loginid_status',
        sub {
            $update_status_params = $_[1];
            return 1;
        }
    )->redefine(
        'record_mt5_transfer',
        sub {
            my $self;
            ($self, $record_transfer_params) = @_;
            return +{result => 1};
        });

    my $verification_status = BOM::MT5::Script::StatusUpdate->new;
    my $response            = await $verification_status->withdraw_and_archive($params);

    is $response->{result},                       1,                  'correct withdrawal and archiving';
    is $update_status_params->{to_status},        'archived',         'correct status to archive user';
    is $withdrawal_amount->{amount},              $mt5_balance,       'correct withdrawal amount';
    is $client_args{amount} + 0,                  $mt5_balance,       'correct transfer amount';
    is $record_transfer_params->{payment_id},     '777',              'correct payment id to store payment';
    is $record_transfer_params->{mt5_account_id}, $params->{loginid}, 'correct loginid to store payment';

    $status_update_mock->unmock_all;

};

subtest 'send_warning_emails' => sub {

    #today 2022-11-3
    $creation_stamp = Date::Utility->new('2022-11-3 1000');

    my $test_client = create_client('CR');
    $test_client->email('test@test.ts');
    $test_client->set_default_account('USD');
    $test_client->binary_user_id(1);
    $test_client->save;

    @test_pending_users = ([
            'MTR100000000', '10000000', $creation_stamp->minus_time_interval(BVI_WARNING_DAYS . 'd')->db_timestamp,
            'poa_pending',  'mt5', 'real', 'USD', $bvi_group_attributes
        ],
        [
            'MTR100000001', '10000001', $creation_stamp->minus_time_interval(BVI_WARNING_DAYS . 'd')->db_timestamp,
            'poa_pending',  'mt5', 'real', 'USD', $bvi_group_attributes
        ],
        [
            'MTR100000002', '10000002', $creation_stamp->minus_time_interval(BVI_WARNING_DAYS . 'd')->db_timestamp,
            'poa_pending',  'mt5', 'real', 'USD', $bvi_group_attributes
        ],
        [
            'MTR100000003', '10000003', $creation_stamp->minus_time_interval(BVI_WARNING_DAYS + 1 . 'd')->db_timestamp,
            'poa_rejected', 'mt5', 'real', 'USD', $bvi_group_attributes
        ],
        [
            'MTR100000004', '10000004', $creation_stamp->minus_time_interval(VANUATU_WARNING_DAYS . 'd')->db_timestamp,
            'poa_pending',  'mt5', 'real', 'USD', $vanuatu_group_attributes
        ],
        [
            'MTR100000005', '10000005', $creation_stamp->minus_time_interval(VANUATU_WARNING_DAYS . 'd')->db_timestamp,
            'poa_pending',  'mt5', 'real', 'USD', $vanuatu_group_attributes
        ],
        [
            'MTR100000006', '10000006', $creation_stamp->minus_time_interval(VANUATU_WARNING_DAYS . 'd')->db_timestamp,
            'poa_rejected', 'mt5', 'real', 'USD', $vanuatu_group_attributes
        ],
        [
            'MTR100000007', '10000007', $creation_stamp->minus_time_interval(VANUATU_WARNING_DAYS . 'd')->db_timestamp,
            'poa_rejected', 'mt5', 'real', 'USD', $vanuatu_group_attributes
        ],
        [
            'MTR100000008', '10000008', $creation_stamp->minus_time_interval(VANUATU_WARNING_DAYS + 2 . 'd')->db_timestamp,
            'poa_rejected', 'mt5', 'real', 'USD', $vanuatu_group_attributes
        ]);

    my @must_sent_warning = ('MTR100000001', 'MTR100000002', 'MTR100000004', 'MTR100000005', 'MTR100000006', 'MTR100000007');

    my %sent_warnings_loginids;
    my $verified_account_loginid;
    my $is_it_warning_flag = 1;
    my $color_changed_loginids;
    my $color;

    $status_update_mock->redefine(
        'load_all_user_data',
        sub {
            my $params = shift;
            return +{
                client      => $test_client,
                user        => 1,                      # in the script this will be BOM::User object
                cr_currency => 'USD',
                bom_loginid => $test_client->loginid
            };
        }
    )->redefine(
        'send_email_to_client',
        sub {
            my $params = $_[1];
            $is_it_warning_flag = 0 if ($params->{email_type} ne 'poa_verification_warning');
            $sent_warnings_loginids{$params->{email_params}->{mt5_account}} = 1;
        }
    )->redefine(
        'gather_users',
        sub {
            @test_pending_users;
        }
    )->redefine(
        'update_loginid_status',
        sub {
            my $params = $_[1];
            $verified_account_loginid = $params->{loginid};
        }
    )->redefine(
        'change_account_color',
        sub {
            my $params = $_[1];
            $color_changed_loginids = $params->{loginid};
            $color                  = $params->{color};
        });

    my $first_account = 1;
    $client_mock->redefine(
        'get_poa_status',
        sub {
            if ($first_account) {
                $first_account = 0;
                return 'verified';
            }
            return 'rejected';
        });

    my $verification_status = BOM::MT5::Script::StatusUpdate->new;
    $verification_status->send_warning_emails();

    foreach my $loginid (@must_sent_warning) {
        ok $sent_warnings_loginids{$loginid}, "warning must be sent for $loginid";
    }

    isnt $sent_warnings_loginids{'MTR100000000'}, 1,              'MTR100000000 account must be skipped because it is verified';
    is $verified_account_loginid,                 'MTR100000000', 'MTR100000000 account status must be updated because it is verified';
    ok $is_it_warning_flag, 'only warning emails';
    is $color_changed_loginids, 'MTR100000000', 'MTR100000000 account color must be changed because it is verified';
    is $color,                  -1,             'MTR100000000 account color must be changed to none because it is verified';
    $status_update_mock->unmock_all;

};

subtest 'send_reminder_emails' => sub {

    #today 2022-11-3
    $creation_stamp = Date::Utility->new('2022-11-3 1000');

    my $test_client = create_client('CR');
    $test_client->email('test@test.ts');
    $test_client->set_default_account('USD');
    $test_client->binary_user_id(1);
    $test_client->save;

    @test_pending_users = ([
            'MTR100000000', '10000000', $creation_stamp->minus_time_interval(BVI_EXPIRATION_DAYS + FIRST_REMINDER_EMAIL_DAYS . 'd')->db_timestamp,
            'poa_failed',   'mt5', 'real', 'USD', $bvi_group_attributes
        ],
        [
            'MTR100000001', '10000001', $creation_stamp->minus_time_interval(BVI_EXPIRATION_DAYS + SECOND_REMINDER_EMAIL_DAYS . 'd')->db_timestamp,
            'poa_failed',   'mt5', 'real', 'USD', $bvi_group_attributes
        ],
        [
            'MTR100000002', '10000002', $creation_stamp->minus_time_interval(BVI_EXPIRATION_DAYS + SECOND_REMINDER_EMAIL_DAYS . 'd')->db_timestamp,
            'poa_failed',   'mt5', 'real', 'USD', $bvi_group_attributes
        ],
        [
            'MTR100000003', '10000003', $creation_stamp->minus_time_interval(BVI_EXPIRATION_DAYS + FIRST_REMINDER_EMAIL_DAYS + 1 . 'd')->db_timestamp,
            'poa_failed',   'mt5', 'real', 'USD', $bvi_group_attributes
        ],
        [
            'MTR100000004', '10000004', $creation_stamp->minus_time_interval(VANUATU_EXPIRATION_DAYS + FIRST_REMINDER_EMAIL_DAYS . 'd')->db_timestamp,
            'poa_failed',   'mt5', 'real', 'USD', $vanuatu_group_attributes
        ],
        [
            'MTR100000005', '10000005', $creation_stamp->minus_time_interval(VANUATU_EXPIRATION_DAYS + FIRST_REMINDER_EMAIL_DAYS . 'd')->db_timestamp,
            'poa_failed',   'mt5', 'real', 'USD', $vanuatu_group_attributes
        ],
        [
            'MTR100000006', '10000006',
            $creation_stamp->minus_time_interval(VANUATU_EXPIRATION_DAYS + SECOND_REMINDER_EMAIL_DAYS . 'd')->db_timestamp,
            'poa_failed', 'mt5', 'real', 'USD', $vanuatu_group_attributes
        ],
        [
            'MTR100000007', '10000007', $creation_stamp->minus_time_interval(VANUATU_EXPIRATION_DAYS + FIRST_REMINDER_EMAIL_DAYS . 'd')->db_timestamp,
            'poa_failed',   'mt5', 'real', 'USD', $vanuatu_group_attributes
        ],
        [
            'MTR100000008', '10000008',
            $creation_stamp->minus_time_interval(VANUATU_EXPIRATION_DAYS + SECOND_REMINDER_EMAIL_DAYS + 2 . 'd')->db_timestamp,
            'poa_failed', 'mt5', 'real', 'USD', $vanuatu_group_attributes
        ]);

    my @must_sent_first_reminder  = ('MTR100000000', 'MTR100000004', 'MTR100000005', 'MTR100000007');
    my @must_sent_second_reminder = ('MTR100000001', 'MTR100000002', 'MTR100000006');

    # only for the sake of tests sending MTR loginids instead of CR
    my @bom_loginids = (
        'MTR100000000', 'MTR100000001', 'MTR100000002', 'MTR100000003', 'MTR100000004', 'MTR100000005',
        'MTR100000006', 'MTR100000007', 'MTR100000008'
    );

    my %sent_reminder_loginids;
    my $loginids_counter = 0;
    my $verified_account_loginid;

    $status_update_mock->redefine(
        'load_all_user_data',
        sub {
            my $params = shift;
            return +{
                client      => $test_client,
                user        => 1,                                    # in the script this will be BOM::User object
                cr_currency => 'USD',
                bom_loginid => $bom_loginids[$loginids_counter++]    # in the script it will be $client->loginid
            };
        }
    )->redefine(
        'send_email_to_client',
        sub {
            my $params = $_[1];
            $sent_reminder_loginids{$params->{email_params}->{loginid}} = 1 if ($params->{email_type} eq 'poa_verification_failed_reminder');
        }
    )->redefine(
        'gather_users',
        sub {
            @test_pending_users;
        }
    )->redefine(
        'update_loginid_status',
        sub {
            my $params = $_[1];
            $verified_account_loginid = $params->{loginid};
        });

    my $verification_status = BOM::MT5::Script::StatusUpdate->new;
    $verification_status->send_reminder_emails();

    foreach my $loginid (@must_sent_first_reminder) {
        ok $sent_reminder_loginids{$loginid}, "first reminder must be sent for $loginid";
        delete $sent_reminder_loginids{$loginid};
    }

    foreach my $loginid (@must_sent_second_reminder) {
        ok $sent_reminder_loginids{$loginid}, "second reminder must be sent for $loginid";
        delete $sent_reminder_loginids{$loginid};
    }

    is %sent_reminder_loginids, 0, 'reminder loginids list must not contain any other loginids';
};

subtest 'check_poa_issuance' => sub {
    my $verification_status = BOM::MT5::Script::StatusUpdate->new;
    my $user                = BOM::User->create(
        email    => 'poa+issuance@binary.com',
        password => 'Test12345',
    );

    $user->add_loginid('MTR10000001', 'mt5', 'real', 'USD', {test => 'test'});
    $user->update_loginid_status('MTR10000001', 'proof_failed');

    $user->add_loginid('MTD10000001', 'mt5', 'demo', 'USD', {test => 'test'});
    $user->update_loginid_status('MTD10000001', 'proof_failed');

    $user->add_loginid('MTR10000002', 'mt5', 'real', 'USD', {group => 'real\p01_ts01\financial\labuan_stp_usd'});
    $user->add_loginid('MTD10000002', 'mt5', 'demo', 'USD', {test  => 'test'});
    $user->dbic->run(
        fixup => sub {
            $_->do('select users.upsert_poa_verification_and_issuance(?,?, ?)', undef, $user->id, '2020-10-10', '2020-10-10');
        });

    my $mock_docs = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments::Config');
    my $boundary;

    $mock_docs->mock(
        'outdated_boundary',
        sub {
            my $category = shift;

            is $category, 'POA', 'category is proof of address';

            return Date::Utility->new($boundary) if $boundary;
            return undef;
        });

    $verification_status->check_poa_issuance();

    cmp_deeply get_loginids_status($user),
        +{
        MTR10000001 => 'proof_failed',
        MTD10000001 => 'proof_failed',
        MTD10000002 => undef,
        MTR10000002 => undef,
        },
        'Nothing changed as the boundary is undef';

    $boundary = '2019-10-10';
    $verification_status->check_poa_issuance();

    cmp_deeply get_loginids_status($user),
        +{
        MTR10000001 => 'proof_failed',
        MTD10000001 => 'proof_failed',
        MTD10000002 => undef,
        MTR10000002 => undef,
        },
        'Nothing changed as the boundary is in the past';

    $boundary = '2020-10-10';
    $verification_status->check_poa_issuance();

    cmp_deeply get_loginids_status($user),
        +{
        MTR10000001 => 'proof_failed',
        MTD10000001 => 'proof_failed',
        MTD10000002 => undef,
        MTR10000002 => undef,
        },
        'Nothing changed as the boundary is in the limit';

    $boundary = '2020-10-11';
    $verification_status->check_poa_issuance();

    cmp_deeply get_loginids_status($user),
        +{
        MTR10000001 => 'proof_failed',
        MTD10000001 => 'proof_failed',
        MTD10000002 => undef,
        MTR10000002 => 'poa_outdated',
        },
        'status updated';
};

subtest 'sync_status_actions' => sub {
    my $test_client = create_client('CR');
    $test_client->email('sync_status_actions@test.co');
    $test_client->set_default_account('USD');
    $test_client->binary_user_id('10000007');
    $test_client->save;

    my $statuses = ['poa_failed', 'proof_failed', 'verification_pending', 'poa_rejected', 'poa_pending', 'poa_outdated'];
    my $dog_logs = [];

    $status_update_mock->mock(
        'stats_event',
        sub {
            push $dog_logs->@*, [@_];
        });

    $status_update_mock->mock(
        'load_all_user_data',
        sub {
            my (undef, $binary_user_id) = @_;
            $test_client->binary_user_id($binary_user_id);
            return +{
                client      => $test_client,
                user        => $binary_user_id,
                cr_currency => 'USD',
                bom_loginid => $test_client->loginid
            };
        });

    my $event_mock = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my $emissions  = [];

    $event_mock->mock(
        'emit',
        sub {
            push $emissions->@*, {@_};
        });

    for my $status ($statuses->@*) {
        $dog_logs  = [];
        $emissions = [];

        $status_update_mock->mock(
            'gather_users',
            sub {
                return ([
                        'MTR100000007', 10000007, Date::Utility->new('2022-09-24 1000')->db_timestamp,
                        $status, 'mt5', 'real', 'USD', $bvi_group_attributes
                    ],
                    [
                        'MTR100000008', 10000007, Date::Utility->new('2022-09-24 1000')->db_timestamp,
                        $status, 'mt5', 'real', 'USD', $bvi_group_attributes
                    ],
                    [
                        'MTR100000007', 10000008, Date::Utility->new('2022-09-24 1000')->db_timestamp,
                        $status, 'mt5', 'real', 'USD', $bvi_group_attributes
                    ],
                    [
                        'MTR100000008', 10000008, Date::Utility->new('2022-09-24 1000')->db_timestamp,
                        $status, 'mt5', 'real', 'USD', $bvi_group_attributes
                    ]);
            });

        my $verification_status = BOM::MT5::Script::StatusUpdate->new;

        $status_update_mock->mock(
            'parse_user',
            sub {
                return {error => 'test'};
            });

        $verification_status->sync_status_actions;

        cmp_deeply $dog_logs,
            [[
                'StatusUpdate.sync_status_actions',
                'Info: Gathered 4 accounts form the DB with status [\'poa_failed\', \'proof_failed\', \'verification_pending\', \'poa_rejected\', \'poa_pending\'] with the newest created at: '
                    . Date::Utility->new('2022-11-3 1245')->datetime_ddmmmyy_hhmmss_TZ,
                {alert_type => 'info'}]
            ],
            'Expected DD log';

        cmp_deeply $emissions, [], 'No emission for an errored mt5 client';

        $status_update_mock->unmock('parse_user');

        $dog_logs  = [];
        $emissions = [];

        $verification_status->sync_status_actions;

        cmp_deeply $dog_logs,
            [[
                'StatusUpdate.sync_status_actions',
                'Info: Gathered 4 accounts form the DB with status [\'poa_failed\', \'proof_failed\', \'verification_pending\', \'poa_rejected\', \'poa_pending\'] with the newest created at: '
                    . Date::Utility->new('2022-11-3 1245')->datetime_ddmmmyy_hhmmss_TZ,
                {alert_type => 'info'}]
            ],
            'Expected DD log';

        cmp_deeply $emissions,
            [{
                sync_mt5_accounts_status => {
                    binary_user_id => 10000007,
                    client_loginid => 'CR10005'
                }
            },
            {
                sync_mt5_accounts_status => {
                    binary_user_id => 10000008,
                    client_loginid => 'CR10005'
                }}
            ],
            'Event emitted once per binary user id';
    }

    $status_update_mock->unmock_all;
    $event_mock->unmock_all;
};

sub get_loginids_status {
    my ($user) = @_;

    my $loginids = $user->dbic->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT loginid, status FROM users.loginid WHERE binary_user_id=?', {Slice => {}}, $user->id);
        });

    return +{map { ($_->{loginid} => $_->{status}) } $loginids->@*};
}

done_testing();
