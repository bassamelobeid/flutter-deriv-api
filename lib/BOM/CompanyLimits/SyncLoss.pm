package BOM::CompanyLimits::SyncLoss;

use strict;
use warnings;

# All code here deals with syncing loss hashes in redis.
# In production, perl scripts using methods here are called via
# crons (possibly daemons in the future) to ensure redis data to
# periodically aligned with the ground truth (database).
#
# We can _never_ assert that what is in Redis is 100% reliable.
# Connection failures, server malfunctions and other unexpected
# crap can cause values in loss type hashes to be out of sync.

use Date::Utility;
use BOM::Database::ClientDB;
use BOM::CompanyLimits;
use BOM::CompanyLimits::Helpers qw(get_redis);
use LandingCompany::Registry;

# Certain loss types reset at the start of a new day. We use a cron
# to periodically set expiryat in redis. For unit tests, we pass a
# param force_reset to delete the hashes immediately.
sub reset_daily_loss_hashes {
    my %params = @_;

    my $new_day_start_epoch = Date::Utility::today()->epoch + 86400;
    my %output;

    my @landing_companies_with_broker_codes = grep { $#{$_->broker_codes} > -1 } LandingCompany::Registry::all();
    foreach my $loss_type (qw/realized_loss turnover/) {
        foreach my $lc (@landing_companies_with_broker_codes) {
            my $landing_company = $lc->{short};
            my $redis           = get_redis($landing_company, $loss_type);
            my $hash_name       = "$landing_company:$loss_type";

            if ($params{force_reset}) {
                $output{$hash_name} = $redis->del($hash_name);
            } else {
                $output{$hash_name} = $redis->expireat($hash_name, $new_day_start_epoch);
            }
        }
    }

    return %output;
}

sub get_db_potential_loss {
    my ($broker_code) = @_;

    return _get_db_loss($broker_code, 'potential_loss', \&_get_key_from_record_with_underlying_group);
}

sub get_db_realized_loss {
    my ($broker_code) = @_;

    return _get_db_loss($broker_code, 'realized_loss', \&_get_key_from_record_with_underlying_group);
}

sub get_db_turnover {
    my ($broker_code) = @_;

    return _get_db_loss($broker_code, 'turnover', \&_get_key_from_record_turnover);
}

sub sync_potential_loss_to_redis {
    my ($broker_code, $landing_company) = @_;

    return _sync_loss_to_redis($broker_code, $landing_company, 'potential_loss', \&get_db_potential_loss, {del_hash => 1});
}

sub update_ultrashort_duration {
# TODO: Ultrashort will be global setting: a range of time between 1-1800 seconds.
#       All expiry_type that is ultrashort and intraday has to be updated in Redis
#       to be in sync with the database. This could potentially update tens of thousands
#       of keys, so we do not expect ultrashort duration to change too often
}

# options = {
#     del_hash => 1 # delete the hash table before setting key values
# }
sub _sync_loss_to_redis {
    my ($broker_code, $landing_company, $loss_type, $get_db_loss_func, $options) = @_;

    my $updated_loss = $get_db_loss_func->($broker_code);
    return undef unless %$updated_loss;

    my $redis = get_redis($landing_company, $loss_type);
    my $hash_name = "$landing_company:$loss_type";

    my $response;
    if ($options->{del_hash}) {
        $redis->multi(sub { });
        $redis->del($hash_name, sub { });
        $redis->hmset($hash_name, %$updated_loss, sub { });
        $redis->exec(sub { $response = $_[1]->[1]; });
        $redis->mainloop;
    } else {
        $response = $redis->hmset($hash_name, %$updated_loss);
    }

    return $response;
}

sub _get_db_loss {
    my ($broker_code, $loss_type, $get_key_func) = @_;
    my $dbic = BOM::Database::ClientDB->new({broker_code => $broker_code})->db->dbic;

    my $db_records = $dbic->run(
        fixup => sub {
            return $_->selectall_arrayref("SELECT * FROM bet.get_${loss_type}_combinations('$broker_code')");
        });

    my %loss_hash;
    foreach my $rec (@$db_records) {
        next if not defined $rec->[5];

        my $key = $get_key_func->($rec);
        $loss_hash{$key} = $rec->[5] + 0;
    }

    return \%loss_hash;
}

sub _get_key_from_record_turnover {
    my ($rec) = @_;
    my $expiry_type    = (defined $rec->[3]) ? $rec->[3] : '+';
    my $contract_group = (defined $rec->[2]) ? $rec->[2] : '+';

    # expiry_type,underlying,contract_group,binary_user_id
    return "$expiry_type,$rec->[1],$contract_group,$rec->[0]";
}

sub _get_key_from_record_with_underlying_group {
    my ($rec) = @_;
    my $expiry_type         = (defined $rec->[3]) ? $rec->[3] : '+';
    my $underlying_or_group = (defined $rec->[1]) ? $rec->[1] : '+';

    # NOTE: $rec->[0] is binary_user_id
    if (defined $rec->[0]) {
        # user specific recs; we need to assume that only underlying_group is used
        return "$expiry_type,$underlying_or_group,$rec->[0]";
    }
    # global recs
    my $barrier_type   = (defined $rec->[4]) ? $rec->[4] : '+';
    my $contract_group = (defined $rec->[2]) ? $rec->[2] : '+';

    return "$expiry_type$barrier_type,$underlying_or_group,$contract_group";
}

1;
