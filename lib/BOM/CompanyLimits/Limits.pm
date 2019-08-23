package BOM::CompanyLimits::Limits;

use strict;
use warnings;

use Error::Base;

use BOM::Config::RedisReplicated;
use BOM::Database::QuantsConfig;
use Future::AsyncAwait;
use BOM::CompanyLimits::Helpers qw(get_redis);

# TODO: It is rather strange to be putting userdb into a bom-transaction repo.
#       We should consider a new repo for this. Perhaps BOM::Limits
use BOM::Database::UserDB;

# TODO: make every function return a ref to make things consistent
# TODO: Validations, a lot of validations, like a lot a lot of it.
# TODO: Unit test everything

my $pack_format = 'N4';

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
    return pack($pack_format, @$values);
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
}

# Takes limits from limits.company_limits and place them inside Redis limits with
# the hash table names "<landing_company>:limits".
sub sync_limits_to_redis {
    my ($date_now) = @_;    # this param is for unit testing only.

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    my $limits = $dbic->run(
        fixup => sub {
            if ($date_now) {
                return $_->selectall_arrayref('SELECT * FROM limits.get_company_limits(?)', {Slice => {}}, ($date_now));
            }

            return $_->selectall_arrayref('SELECT * FROM limits.get_company_limits()', {Slice => {}});
        });

    foreach my $landing_company (qw/svg mlt mf mx/) {
        my $redis = get_redis($landing_company, 'limit_setting');
        my %key_value_pair;
        foreach my $limit (@$limits) {
            if (   $limit->{landing_company} eq '*'
                or $limit->{landing_company} eq $landing_company)
            {
                if ($limit->{binary_user_id}) {    # global limits

                } else {                           # user specific limits

                }
            }
        }
    }
}

1;
