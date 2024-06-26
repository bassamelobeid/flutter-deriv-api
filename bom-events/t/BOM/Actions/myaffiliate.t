use strict;
use warnings;

use Future;
use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::Deep;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Email;
use BOM::User;
use BOM::Event::Actions::MyAffiliate;
use BOM::Event::Utility qw(exception_logged);
use BOM::User::Password;
use Future::AsyncAwait;
use Clone qw(clone);

my $email    = 'abc' . rand . '@binary.com';
my $hash_pwd = BOM::User::Password::hashpw('test');

my $ib_user = BOM::User->create(
    email    => "ib-$email",
    password => $hash_pwd,
);

my $ib_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    binary_user_id => $ib_user->id
});

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd,
);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    binary_user_id => $user->id
});

$test_client->set_default_account('USD');

$email = 'abc' . rand . '@binary.com';
my $user_deriv = BOM::User->create(
    email    => $email,
    password => $hash_pwd,
);
my $test_client_deriv = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    binary_user_id => $user_deriv->id
});
$test_client_deriv->set_default_account('USD');

my $mock_myaffiliate = Test::MockModule->new('BOM::MyAffiliates');
my $mock_client      = Test::MockModule->new('BOM::User::Client');
my $date_joined      = Date::Utility->new('2020-01-01');
$mock_client->redefine('date_joined' => sub { return $date_joined->date_yyyymmdd; });

# at MyAffiliates we are maintaining separate CLIENT_ID for deriv & binary.
# the affiliates that are associated with deriv have CLIENT_ID prefixed with deriv_
# Sometimes it will send duplicates, they should be removed.
my $mtr_loginid = $test_client->loginid;
my $ctr_loginid = $test_client->loginid;
$mtr_loginid =~ s/^CR/MTR/;
$ctr_loginid =~ s/^CR/CTR/;

my $customers = [
    {"CLIENT_ID" => $test_client->loginid},
    {"CLIENT_ID" => 'deriv_' . $test_client_deriv->loginid},
    {"CLIENT_ID" => $mtr_loginid},
    {"CLIENT_ID" => $test_client->loginid},
    {"CLIENT_ID" => $ctr_loginid}];

my $affiliate_id = 1234;

my $first_call = 1;
my @dates_batch;

my $err_str = 'Gateway Time-out';
$mock_myaffiliate->redefine(
    'get_customers' => sub {
        shift;
        my %args = @_;
        if ($first_call) {
            $first_call = 0;
            return [];
        }

        push @dates_batch, $args{FROM_DATE} . ' ' . $args{TO_DATE};
        return $customers;
    },
    'errstr' => sub {
        return $err_str;
    },
    'reset_errstr' => sub {
        $err_str = '';
    });

my @expected_dates_batch;

# The first batch will fail so the date batch will be reduced by half
my $months    = BOM::Event::Actions::MyAffiliate::AFFILIATE_BATCH_MONTHS / 2;
my $date_from = Date::Utility->new->minus_months($months);
my $date_to   = Date::Utility->new;

while ($date_to->is_after($date_joined) || $date_to->is_same_as($date_joined)) {
    push @expected_dates_batch, $date_from->date_yyyymmdd . ' ' . $date_to->date_yyyymmdd;
    $date_to   = $date_from->minus_time_interval('1d');
    $date_from = $date_from->minus_months($months);
}

subtest "clean loginids" => sub {
    my $expected_result = set($test_client->loginid, $test_client_deriv->loginid);
    cmp_deeply BOM::Event::Actions::MyAffiliate::_get_clean_loginids($ib_client->date_joined, $affiliate_id), $expected_result,
        'correct loginids after clean';
    cmp_deeply \@dates_batch, \@expected_dates_batch, 'correct dates for batching';
};

my $emitter_mock = Test::MockModule->new('BOM::Platform::Event::Emitter');
my $emission     = {};
$emitter_mock->mock(
    'emit',
    sub {
        my ($event, $data) = @_;
        $emission->{$event}->{counter}++;
        push $emission->{$event}->{data}->@*, $data;
    });

my $event_mock = Test::MockModule->new('BOM::Event::Actions::MyAffiliate');
my $chunk_size = BOM::Event::Actions::MyAffiliate::AFFILIATE_CHUNK_SIZE;

subtest "affiliate_sync_initiated" => sub {
    # in this test we will ensure the splice work as expected.
    my $times = 5;
    $customers = [];
    for my $i (0 .. $chunk_size * $times - 1) {
        push $customers->@*, {CLIENT_ID => 'CR000' . $i};
    }

    # note the last batch is processed righ away instead of firing up a new event
    my $last_batch_data;
    $event_mock->mock(
        'affiliate_loginids_sync',
        sub {
            $last_batch_data = shift;
            return Future->done(undef);
        });

    lives_ok {
        BOM::Event::Actions::MyAffiliate::affiliate_sync_initiated({
                affiliate_id => $affiliate_id,
                mt5_login    => undef,
                email        => $test_client->email,
                action       => 'sync',
            })->get;
    }
    "affiliate_sync_initiated no exception";

    # Note the last batch does not emit a new event, thus we'd expect: $times - 1
    is $emission->{affiliate_loginids_sync}->{counter}, $times - 1, 'Expected number of emissions';

    for my $data ($emission->{affiliate_loginids_sync}->{data}->@*) {
        cmp_deeply $data,
            {
            affiliate_id => $affiliate_id,
            email        => $test_client->email,
            loginids     => [(map { $_->{CLIENT_ID} } splice $customers->@*, 0, $chunk_size)],
            action       => 'sync',
            client       => undef,
            untag        => 0,
            },
            'Expected data emitted for this chunk';
    }

    cmp_deeply $last_batch_data,
        {
        affiliate_id => $affiliate_id,
        email        => $test_client->email,
        loginids     => [(map { $_->{CLIENT_ID} } splice $customers->@*, 0, $chunk_size)],
        action       => 'sync',
        client       => undef,
        untag        => 0,
        },
        'Expected last chunk of data processed';

    subtest 'Less than chunk size' => sub {

        # let it send the email to prove both event emission and await call properly work
        $event_mock->redefine(
            'affiliate_loginids_sync' => sub {
                $last_batch_data = $_[0];
                return $event_mock->original('affiliate_loginids_sync')->(@_);
            },
            '_archive_technical_accounts' => async sub {
                return {
                    success                          => ['MTR123456'],
                    main_account_ib_removal_success  => ['MTR00001', 'MTR00002'],
                    main_account_ib_removal_failed   => ['MTR00003 - Some error'],
                    failed                           => [],
                    account_not_found                => [],
                    technical_account_balance_exists => [],
                };
            });

        $emission  = {};
        $customers = [];
        for my $i (0 .. $chunk_size - 1) {
            push $customers->@*, {CLIENT_ID => 'CR000' . $i};
        }

        mailbox_clear();
        lives_ok {
            BOM::Event::Actions::MyAffiliate::affiliate_sync_initiated({
                    affiliate_id  => $affiliate_id,
                    deriv_loginid => $ib_client->loginid,
                    email         => $test_client->email,
                    action        => 'clear',
                    untag         => 1,
                })->get;
        }
        "affiliate_sync_initiated no exception";

        cmp_deeply $emission, {}, 'No additional event emitted';
        is $last_batch_data->{action},       'clear',             'Correct action';
        is $last_batch_data->{untag},        1,                   'Correct untag';
        is $last_batch_data->{affiliate_id}, $affiliate_id,       'Correct affiliate_id';
        is $last_batch_data->{email},        $test_client->email, 'Correct email';
        cmp_deeply $last_batch_data->{loginids}, [map { $_->{CLIENT_ID} } $customers->@*], 'Correct loginids';
        ok $last_batch_data->{client}, 'Client is found';

        my $msg = mailbox_search(subject => qr/Affiliate $affiliate_id Untagging/);
        like($msg->{body}, qr/Untagging for Affiliate $affiliate_id/, "Correct user in message");
        my $s = '(\n|\s|\t)*';
        like(
            $msg->{body},
            qr(Main Account Archived - IB Comment Removed$s</h2><br><ul>$s<li>MTR00001</li>$s<li>MTR00002),
            "Correct archived loginids in message"
        );
        is($msg->{from}, 'no-reply@binary.com', 'Correct from Address');
    };
};

subtest "affiliate_loginids_sync" => sub {
    $event_mock->unmock('affiliate_loginids_sync');

    # In this test we will check the process as it used to be, each chunk separately.
    $customers = [{"CLIENT_ID" => $test_client->loginid}, {"CLIENT_ID" => 'deriv_' . $test_client_deriv->loginid}, {"CLIENT_ID" => $mtr_loginid}];

    mailbox_clear();
    lives_ok {
        BOM::Event::Actions::MyAffiliate::affiliate_loginids_sync({
                affiliate_id => $affiliate_id,
                email        => 'some_compliance@email.com',
                login_ids    => [map { $_->{CLIENT_ID} } $customers->@*],
                action       => 'sync',
            })->get;
    }
    "affiliate_loginids_sync no exception";

    my $msg = mailbox_search(subject => qr/Affiliate $affiliate_id Synchronization to MT5/);
    like($msg->{body}, qr/Synchronization to MT5 for Affiliate $affiliate_id/, "Correct user in message");
    is($msg->{from}, 'no-reply@binary.com', 'Correct from Address');
};

subtest "populate_mt5_affiliate_to_client" => sub {
    my $populate_aff_result = BOM::Event::Actions::MyAffiliate::_populate_mt5_affiliate_to_client('CR123456', 123456);

    cmp_deeply $populate_aff_result->{result}[0], ['CR123456: not a valid loginid'], 'Correct error message when login is incorrect';

    $populate_aff_result = BOM::Event::Actions::MyAffiliate::_populate_mt5_affiliate_to_client($test_client->loginid, 123456);

    cmp_deeply $populate_aff_result->{result}[0], ['Affiliate token not found for ' . $test_client->loginid],
        'Correct error message when token is not found';

    $test_client->myaffiliates_token('FakeToken');
    $test_client->save;

    $mock_myaffiliate->mock(
        'get_affiliate_id_from_token' => sub {
            return '';
        });

    $populate_aff_result = BOM::Event::Actions::MyAffiliate::_populate_mt5_affiliate_to_client($test_client->loginid, 123456);
    cmp_deeply $populate_aff_result->{result}[0], ["Could not match the affiliate 123456 based on the provided token 'FakeToken'"],
        'Correct error message when affiliates do not match';

    my $bom_user = Test::MockModule->new('BOM::User');

    $bom_user->mock(
        'mt5_logins' => sub {
            return 'MTR400123456';
        });

    $mock_myaffiliate->mock(
        'get_affiliate_id_from_token' => sub {
            return 123456;
        });

    $event_mock->mock(
        '_set_affiliate_for_mt5' => async sub {
            return '654321';
        });

    $populate_aff_result = BOM::Event::Actions::MyAffiliate::_populate_mt5_affiliate_to_client($test_client->loginid, 123456);
    cmp_deeply $populate_aff_result->{result}[0], [$test_client->loginid . ': account MTR400123456 agent updated to 654321'],
        'Correct message when agent is set for client';

    $event_mock->mock(
        '_set_affiliate_for_mt5' => async sub {
            die "Testing error message";
        });

    $populate_aff_result = BOM::Event::Actions::MyAffiliate::_populate_mt5_affiliate_to_client($test_client->loginid, 123456);

    my $res = index($populate_aff_result->{result}[0][0], $test_client->loginid . ': account MTR400123456 had an error: Testing error message');

    is $res, 0, 'Correct error message when setting affiliate for client';
};

done_testing();
