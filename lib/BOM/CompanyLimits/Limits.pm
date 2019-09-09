package BOM::CompanyLimits::Limits;

use strict;
use warnings;

use Error::Base;
use List::Util qw(min);

use BOM::Database::QuantsConfig;
use BOM::CompanyLimits::Helpers qw(get_redis);

use BOM::Database::UserDB;

# NOTE: For user specific limits, because only underlying group is specified,
# we need to infer behavior when g is defined or left default (u and g are
# specific underlying and underlying group):
#
#      loss_type     | underlying_group | underlying
# -------------------+------------------+------------
# turnover           |      g           |     *
# realized+potential |      g           |     +
# turnover           |      * (default) |     *
# realized+potential |      + (default) |     +
#
# To reuse the same limit settings, eventhough for turnover the behaviour when
# underlying group is not defined is '* *' (per underlying for all underlying),
# it is set as '+' and needs to be inferred.
sub query_limits {
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

my $pack_format = '(c/a)*';

sub pack_limit_values {
    my ($values) = @_;
    return pack($pack_format, map { defined $_ ? $_ : '' } @$values);
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

    return;
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

    foreach my $landing_company (keys %$all_limits) {
        my $redis     = get_redis($landing_company, 'limit_setting');
        my $limits    = $all_limits->{$landing_company};
        my @keyvals   = map { $_ => pack_limit_values($limits->{$_}) } keys %$limits;
        my $hash_name = "$landing_company:limits";

        $redis->multi(sub { });
        $redis->del($hash_name, sub { });
        $redis->hmset($hash_name, @keyvals, sub { }) if @keyvals;
        $redis->exec(sub { });
        $redis->mainloop;
    }

    return;
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
                        _coalesce_min($val->[0], $limit->{potential_loss}),
                        _coalesce_min($val->[1], $limit->{realized_loss}),
                        _coalesce_min($val->[2], $limit->{turnover}),
                        _coalesce_min($val->[3], $limit->{payout}),
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

# takes the min if both params are defined, otherwise take the first defined
sub _coalesce_min {
    my ($x, $y) = @_;
    return min($x, $y) if (defined $x and defined $y);
    return $x || $y;
}

1;
