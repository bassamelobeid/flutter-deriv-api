#!/usr/bin/perl

use strict;
use warnings;

use BOM::Database::UserDB;
use BOM::Database::CommissionDB;
use BOM::User;
use BOM::Platform::Event::Emitter;
use Getopt::Long;
use Log::Any::Adapter qw(DERIV),
    stderr    => 'json',
    log_level => $ENV{BOM_LOG_LEVEL} // 'info';
use Log::Any qw($log);

# publishing events at 5-second interval by default
my $interval = 5;
# number of events to be published at each interval
my $max_count    = 50;
my $account_type = 'real';
my $platform;
# populate from the beginning. Should only be done during initial setup
my $all = 0;
my $now = Date::Utility->today;

GetOptions(
    "interval=i"     => \$interval,
    "count=i"        => \$max_count,
    "platform=s"     => \$platform,
    "account_type=s" => \$account_type,
    "date=s"         => \$now,
    "all=i"          => \$all,
) or die "Error in arguments";

die "platform is required" unless $platform;

my $user_query        = q{SELECT binary_user_id, loginid FROM users.loginid WHERE platform=? AND account_type=?};
my @user_query_params = ($platform, $account_type);
my $aff_query         = q{SELECT id FROM affiliate.affiliate_client WHERE provider=?};
my @aff_query_params  = ($platform);

unless ($all) {
    my $from = $now->minus_time_interval('1d');
    $user_query =
        q{SELECT binary_user_id, loginid FROM users.loginid WHERE platform=? AND account_type=? AND creation_stamp > ? AND creation_stamp <= ?};
    push @user_query_params, $from->db_timestamp, $now->db_timestamp;

    $aff_query = q{SELECT id FROM affiliate.affiliate_client WHERE provider=? AND created_at > ? AND created_at <= ?};
    push @aff_query_params, $from->db_timestamp, $now->db_timestamp;
}

my $userdb = BOM::Database::UserDB::rose_db(operation => 'replica');
my $users  = $userdb->dbic->run(
    fixup => sub {
        $_->selectall_arrayref($user_query, undef, @user_query_params);
    });

my $commissiondb         = BOM::Database::CommissionDB::rose_db();
my $existing_aff_clients = $commissiondb->dbic->run(
    fixup => sub {
        $_->selectall_arrayref($aff_query, undef, @aff_query_params);
    });
my %existing = map { $_->[0] => 1 } @$existing_aff_clients;

my $total = scalar(@$users);
$log->debugf("%s records found", $total);

my $starting_count  = 0;
my $total_processed = 0;
my $total_skip      = 0;
foreach my $data (@$users) {
    if ($starting_count >= $max_count) {
        $total_processed += $starting_count;
        $log->debugf("Processed %s & skipped %s out of total %s records", $total_processed, $total_skip, $total);
        sleep $interval;
        $starting_count = 0;
    }
    my ($binary_user_id, $loginid) = @$data;

    if ($existing{$loginid}) {
        $total_skip++;
        next;
    }

    my $user = BOM::User->new(id => $binary_user_id);

    foreach my $bom_loginid ($user->bom_loginids) {
        my $client = BOM::User::Client->new({loginid => $bom_loginid});
        if (my $token = $client->myaffiliates_token) {
            BOM::Platform::Event::Emitter::emit(
                'cms_add_affiliate_client',
                {
                    binary_user_id => $binary_user_id,
                    platform       => $platform,
                    loginid        => $loginid,
                    token          => $token
                });
            $starting_count++;
            last;
        }
    }
}

