use strict;
use warnings;
use BOM::Config;
use BOM::Config::Redis;
use BOM::Database::ClientDB;
use BOM::Database::UserDB;
use LandingCompany::Registry;
use Getopt::Long;
use Log::Any::Adapter;
use Log::Any qw($log);

=head2 p2p_populate_advertiser_onine_history.pl

Manual script to regenerate online times stats in redis for all p2p advertisers.
The online time is an optimistic estimate, since we don't know if they used P2P in the session.
It is safe to run this script multiple times, existing redis values will not be changed.

=cut

GetOptions('l|log=s' => \my $log_level);
Log::Any::Adapter->import(qw(DERIV), log_level => $log_level // 'info');

# Apps which have P2P functionality
my @apps = (
    1408,     # DP2P mobile
    16303,    # DTrader - staging
    16929,    # DTrader
    11780,    # Deriv-com
    1411,     # Deriv-me
    30767,    # Deriv-be
);

my @brokers = map { $_->{broker_codes}->@* } grep { $_->{p2p_available} } values LandingCompany::Registry::get_loaded_landing_companies()->%*;
my %users;

for my $broker (@brokers) {
    my $db = BOM::Database::ClientDB->new({
            broker_code  => $broker,
            db_operation => 'replica'
        })->db->dbic;

    my $data = $db->run(
        fixup => sub {
            $_->selectall_arrayref(
                'SELECT a.client_loginid, c.binary_user_id, c.residence
                 FROM p2p.p2p_advertiser AS a 
                 JOIN betonmarkets.client AS c ON c.loginid = a.client_loginid',
                {Slice => {}});

        });

    $log->debugf('got %i advertisers for %s', scalar(@$data), $broker);
    $users{$_->{binary_user_id}} = ($_->{client_loginid} . "::" . $_->{residence}) for @$data;
}

my $user_db = BOM::Database::UserDB::rose_db(operation => 'replica')->dbic;
my $redis   = BOM::Config::Redis->redis_p2p_write();

my @all_userids = keys %users;
my $updates     = 0;

while (my @chunk = splice(@all_userids, 0, 100)) {
    $log->debug('processing batch of 100');

    my $logins = $user_db->run(
        fixup => sub {
            $_->selectall_arrayref(
                "SELECT binary_user_id AS id, EXTRACT('epoch' FROM MAX(history_date)) AS epoch 
                 FROM users.login_history 
                 WHERE binary_user_id = ANY (?)
                 AND app_id = ANY (?)
                 AND history_date > NOW() - '6 month'::INTERVAL
                 AND successful 
                 GROUP BY binary_user_id",
                {Slice => {}},
                \@chunk, \@apps
            );
        });

    $log->debugf('got app login times for %i advertisers', scalar(@$logins));

    for my $login (@$logins) {
        # unfortunately our redis version does not the support LT flag for zadd
        $updates += $redis->zadd('P2P::USERS_ONLINE', 'NX', $login->{epoch}, $users{$login->{id}});
    }
}

$log->debugf('%i times updated in redis', $updates);
