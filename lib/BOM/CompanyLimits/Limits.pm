package BOM::CompanyLimits::Limits;

use strict;
use warnings;

use Error::Base;

use BOM::Config::RedisReplicated;
use BOM::Database::QuantsConfig;
use Future::AsyncAwait;
use BOM::CompanyLimits::Helpers qw(get_redis);

use BOM::Database::UserDB;

# TODO: make every function return a ref to make things consistent
# TODO: Validations, a lot of validations, like a lot a lot of it.
# TODO: Unit test everything

my $pack_format = '(c/a)*';

async sub query_limits {
    my ($landing_company, $combinations) = @_;
    my $redis = get_redis($landing_company, 'limit_setting');
    my $limits_response = $redis->hmget("$landing_company:limits", @$combinations);

    my %limits;
    foreach my $i (0 .. $#$combinations) {
        if ($limits_response->[$i]) {
            $limits{$combinations->[$i]} = unpack_limit_values($limits_response->[$i]);
        }
    }

    return \%limits;
}

sub pack_limit_values {
    my ($values) = @_;
    return pack($pack_format, map { $_ || '' } @$values);
}

sub unpack_limit_values {
    my ($packed) = @_;
    my @unpacked = unpack($pack_format, $packed);
    return \@unpacked;
}

# This single function performs all CRUD operations in limits.company_limits table.
# Because you cannot have more than 1 limit with the same attributes, a limit is either
# added or overwritten by passing the same attributes. To delete, simply remove the
# limit_amount.
sub update_company_limits {
    my ($args) = @_;
    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    my @db_params = @$args{
        qw/landing_company client_loginid underlying_group underlying
            contract_group expiry_type barrier_type
            limit_type limit_amount start_time end_time comment/
    };

    $dbic->run(
        fixup => sub {
            my $sth = $_->prepare('SELECT * FROM limits.update_company_limits(?,?,?,?,?,?,?,?,?,?,?,?)');
            $sth->execute(@db_params);
        });

    sync_limits_to_redis();
}

# Takes limits from limits.company_limits and place them inside Redis limits with
# the hash table names "<landing_company>:limits".
sub sync_limits_to_redis {
    my ($date_now) = @_;    # this param is for unit testing only.

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    my $db_records = $dbic->run(
        fixup => sub {
            if ($date_now) {
                return $_->selectall_arrayref('SELECT * FROM limits.get_company_limits(?)', {Slice => {}}, ($date_now));
            }

            return $_->selectall_arrayref('SELECT * FROM limits.get_company_limits()', {Slice => {}});
        });

    my $all_limits = _get_landing_company_limits_map($db_records);

    while (my ($landing_company, $limits) = each %$all_limits) {
        my $redis = get_redis($landing_company, 'limit_setting');
        my @keyvals = map { $_ => pack_limit_values($limits->{$_}) } keys %$limits;
        my $hash_name = "$landing_company:limits";

        $redis->multi(sub { });
        $redis->del($hash_name, sub { });
        $redis->hmset($hash_name, @keyvals, sub { }) if @keyvals;
        $redis->exec(sub { });
        $redis->mainloop;
    }
}

# take database records and turn it to the format:
# {
#     svg => {
#          tn,R_50,callput => [100, undef, undef, 50]
#     },
#     mf  => { ... }
# }
sub _get_landing_company_limits_map {
    my ($db_records) = @_;

    my $all_limits;
    foreach my $landing_company (qw/svg mlt mf mx/) {
        my $redis = get_redis($landing_company, 'limit_setting');
        my $landing_company_limits;
        foreach my $limit (@$db_records) {
            if (   $limit->{landing_company} eq '*'
                or $limit->{landing_company} eq $landing_company)
            {
                # There can be overlaps between '*' and specific landing companies.
                # In this scenario we take the min of the 2
                my $key = get_key_from_limit_record($limit);
                if (exists $landing_company_limits->{$key}) {
                    my $val = $landing_company_limits->{$key};
                    $landing_company_limits->{$key} = [
                        min($val->[0], $limit->{potential_loss}),
                        min($val->[1], $limit->{realized_loss}),
                        min($val->[2], $limit->{turnover}),
                        min($val->[3], $limit->{payout}),
                    ];
                } else {
                    $landing_company_limits->{$key} = [$limit->{potential_loss}, $limit->{realized_loss}, $limit->{turnover}, $limit->{payout}];
                }
            }
        }

        $all_limits->{$landing_company} = $landing_company_limits;
    }

    return $all_limits;
}

sub get_key_from_limit_record {
    my ($limit) = @_;

    # conveniently, the first character here is the attribute
    my $expiry_type = substr($limit->{expiry_type}, 0, 1);
    if ($limit->{binary_user_id}) {
        # user specific limits; we need to assume that only underlying_group is used
        return "$expiry_type,$limit->{underlying_or_group},$limit->{binary_user_id}";
    }
    # global limits
    my $barrier_type = substr($limit->{barrier_type}, 0, 1);
    return "$expiry_type$barrier_type,$limit->{underlying_or_group},$limit->{contract_group}";
}

1;
