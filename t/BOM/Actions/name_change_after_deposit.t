use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::MockModule;
use Test::Deep;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Email;
use BOM::User::Client;
use BOM::Event::Actions::Client;

my $client;
my $offset = 0;

subtest 'name checks' => sub {

    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'namechange1@test.com',
        first_name  => 'brad',
        last_name   => 'pitt',
    });

    BOM::User->create(
        email    => $client->email,
        password => 'test',
    )->add_client($client);

    $client->account('USD');
    $client->db->dbic->dbh->do("UPDATE audit.client SET stamp = '2020-01-01'::TIMESTAMP WHERE loginid = ?", undef, $client->loginid);

    my $offset = 0;

    change_name('bob', 'smith');
    BOM::Event::Actions::Client::check_name_changes_after_first_deposit({loginid => $client->loginid});
    ok !BOM::User::Client->new({loginid => $client->loginid})->status->withdrawal_locked, 'not withdrawal locked before first deposit';
    BOM::Test::Email::mailbox_check_empty('no email sent');

    df_deposit(100);
    BOM::Event::Actions::Client::check_name_changes_after_first_deposit({loginid => $client->loginid});
    ok !BOM::User::Client->new({loginid => $client->loginid})->status->withdrawal_locked, 'not withdrawal locked after first deposit';
    BOM::Test::Email::mailbox_check_empty('no email sent');

    change_name('smith', 'bob');
    BOM::Event::Actions::Client::check_name_changes_after_first_deposit({loginid => $client->loginid});
    ok !BOM::User::Client->new({loginid => $client->loginid})->status->withdrawal_locked, 'not withdrawal locked after name flip';
    BOM::Test::Email::mailbox_check_empty('no email sent');

    change_name('bob', 'smyth');
    BOM::Event::Actions::Client::check_name_changes_after_first_deposit({loginid => $client->loginid});
    ok !BOM::User::Client->new({loginid => $client->loginid})->status->withdrawal_locked, 'not withdrawal locked after minor change';
    BOM::Test::Email::mailbox_check_empty('no email sent');

    change_name('mary', 'jane');
    BOM::Event::Actions::Client::check_name_changes_after_first_deposit({loginid => $client->loginid});
    ok my $status = BOM::User::Client->new({loginid => $client->loginid})->status->withdrawal_locked, 'withdrawal locked after big change';
    is $status->{reason}, 'Excessive name changes after first deposit - pending POI', 'correct reason';

    my $msg = BOM::Test::Email::mailbox_search(
        subject => qr/Account verification/,
        email   => $client->email
    );
    ok $msg, 'email sent';

    BOM::Test::Email::mailbox_clear();
    BOM::Event::Actions::Client::check_name_changes_after_first_deposit({loginid => $client->loginid});
    BOM::Test::Email::mailbox_check_empty('email not sent if already withdrawal_locked');

    # legacy client with no name set
    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'namechange2@test.com',
        first_name  => '',
        last_name   => '',
    });

    BOM::User->create(
        email    => $client->email,
        password => 'test',
    )->add_client($client);
    $client->db->dbic->dbh->do("UPDATE audit.client SET stamp = '2020-01-01'::TIMESTAMP + INTERVAL '1 day ' * ? WHERE loginid = ?",
        undef, $offset, $client->loginid);

    df_deposit(100);
    change_name('new', 'name');
    BOM::Test::Email::mailbox_clear();
    BOM::Event::Actions::Client::check_name_changes_after_first_deposit({loginid => $client->loginid});
    ok !BOM::User::Client->new({loginid => $client->loginid})->status->withdrawal_locked, 'not withdrawal locked after set name from empty';
    BOM::Test::Email::mailbox_check_empty('no email sent');
};

subtest 'deposit event' => sub {
    my $emitted;
    my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
    $mock_events->mock(emit => sub { $emitted->{$_[0]} = $_[1] });

    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'namechange3@test.com',
    });
    $client->account('USD');

    BOM::Event::Actions::Client::payment_deposit({
        loginid            => $client->loginid,
        account_identifier => $client->account->id
    });
    cmp_deeply($emitted->{check_name_changes_after_first_deposit}, {loginid => $client->loginid}, 'event emitted from deposit');
};

done_testing();

sub change_name {
    my ($first, $last) = @_;

    $client->first_name($first);
    $client->last_name($last);
    $client->save;
    $client->db->dbic->dbh->do(
        "UPDATE audit.client SET stamp = '2020-01-01'::TIMESTAMP + INTERVAL '1 day' * ? WHERE first_name = ? and last_name = ? AND loginid = ?",
        undef, ++$offset, $first, $last, $client->loginid);
}

sub df_deposit {
    my ($amount) = @_;

    my $tx = $client->payment_doughflow(
        currency => $client->currency,
        amount   => $amount,
        remark   => 'x',
    );

    $client->db->dbic->dbh->do("UPDATE payment.payment SET payment_time = '2020-01-01'::TIMESTAMP + INTERVAL '1 day' * ? WHERE id = ?",
        undef, ++$offset, $tx->payment_id);

}
