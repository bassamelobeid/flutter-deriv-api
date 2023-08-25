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
use Future;

my $email    = 'abc' . rand . '@binary.com';
my $hash_pwd = BOM::User::Password::hashpw('test');
my $user     = BOM::User->create(
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

# at MyAffiliates we are maintaining separate CLIENT_ID for deriv & binary.
# the affiliates that are associated with deriv have CLIENT_ID prefixed with deriv_
# Sometimes it will send duplicates, they should be removed.
my $mtr_loginid = $test_client->loginid;
$mtr_loginid =~ s/^CR/MTR/;
my $customers = [
    {"CLIENT_ID" => $test_client->loginid},
    {"CLIENT_ID" => 'deriv_' . $test_client_deriv->loginid},
    {"CLIENT_ID" => $mtr_loginid},
    {"CLIENT_ID" => $test_client->loginid}];
my $affiliate_id = 1234;
$mock_myaffiliate->mock(
    'get_customers' => sub {
        return $customers;
    });
subtest "clean loginids" => sub {
    my $expected_result = set($test_client->loginid, $test_client_deriv->loginid);
    cmp_deeply BOM::Event::Actions::MyAffiliate::_get_clean_loginids($affiliate_id), $expected_result, 'correct loginids after clean';
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
            affiliate_id  => $affiliate_id,
            email         => $test_client->email,
            loginids      => [(map { $_->{CLIENT_ID} } splice $customers->@*, 0, $chunk_size)],
            action        => 'sync',
            deriv_loginid => undef,
            untag         => 0,
            },
            'Expected data emitted for this chunk';
    }

    cmp_deeply $last_batch_data,
        {
        affiliate_id  => $affiliate_id,
        email         => $test_client->email,
        loginids      => [(map { $_->{CLIENT_ID} } splice $customers->@*, 0, $chunk_size)],
        action        => 'sync',
        deriv_loginid => undef,
        untag         => 0,
        },
        'Expected last chunk of data processed';

    subtest 'Less than chunk size' => sub {
        # let it send the email to prove both event emission and await call properly work
        $event_mock->mock(
            'affiliate_loginids_sync',
            sub {
                $last_batch_data = $_[0];
                return $event_mock->original('affiliate_loginids_sync')->(@_);
            });

        $emission  = {};
        $customers = [];
        for my $i (0 .. $chunk_size - 1) {
            push $customers->@*, {CLIENT_ID => 'CR000' . $i};
        }

        mailbox_clear();
        lives_ok {
            BOM::Event::Actions::MyAffiliate::affiliate_sync_initiated({
                    affiliate_id => $affiliate_id,
                    mt5_login    => undef,
                    email        => $test_client->email,
                    action       => 'clear',
                })->get;
        }
        "affiliate_sync_initiated no exception";

        cmp_deeply $emission, {}, 'No additional event emitted';
        cmp_deeply $last_batch_data,
            {
            affiliate_id  => $affiliate_id,
            email         => $test_client->email,
            loginids      => [map { $_->{CLIENT_ID} } $customers->@*],
            action        => 'clear',
            deriv_loginid => undef,
            untag         => 0,
            },
            'Expected data processed';

        my $msg = mailbox_search(subject => qr/Affiliate $affiliate_id synchronization to mt5/);
        like($msg->{body}, qr/Synchronization to mt5 for Affiliate $affiliate_id/, "Correct user in message");
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
                email        => $test_client->email,
                login_ids    => [map { $_->{CLIENT_ID} } $customers->@*],
                action       => 'sync',
            })->get;
    }
    "affiliate_loginids_sync no exception";

    my $msg = mailbox_search(subject => qr/Affiliate $affiliate_id synchronization to mt5/);
    like($msg->{body}, qr/Synchronization to mt5 for Affiliate $affiliate_id/, "Correct user in message");
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
