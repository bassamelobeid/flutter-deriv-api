package BOM::CompanyLimits;
use strict;
use warnings;

use BOM::Database::ClientDB;
use BOM::Config::RedisReplicated;
use Date::Utility;
use Data::Dumper;
use BOM::CompanyLimits::Helpers;
use BOM::CompanyLimits::Limits;

=head1 NAME


=cut

sub set_limits {
    my ($limit_def) = @_;
}

sub set_underlying_groups {
    # POC, we should see which broker code to use
    my $dbic = BOM::Database::ClientDB->new({broker_code => 'CR'})->db->dbic;

    my $sql = q{
	SELECT symbol, market FROM bet.market;
    };
    my $bet_market = $dbic->run(fixup => sub { $_->selectall_arrayref($sql, undef) });

    my @symbol_underlying;
    push @symbol_underlying, @$_ foreach (@$bet_market);
    BOM::Config::RedisReplicated::redis_limits_write->hmset('UNDERLYINGGROUPS', @symbol_underlying);
}

sub set_contract_groups {
    # POC, we should see which broker code to use
    my $dbic = BOM::Database::ClientDB->new({broker_code => 'CR'})->db->dbic;

    my $sql = q{
	SELECT bet_type, contract_group FROM bet.contract_group;
    };
    my $bet_grp = $dbic->run(fixup => sub { $_->selectall_arrayref($sql, undef) });

    my @contract_grp;
    push @contract_grp, @$_ foreach (@$bet_grp);
    BOM::Config::RedisReplicated::redis_limits_write->hmset('CONTRACTGROUPS', @contract_grp);
}

sub add_contract {
    my ($contract) = @_;
    my $bet_data = $contract->{bet_data};

    my $underlying = $bet_data->{underlying_symbol};
    my ($contract_group, $underlying_group);
    BOM::Config::RedisReplicated::redis_limits_write->hget(
        'CONTRACTGROUPS',
        $bet_data->{bet_type},
        sub {
            $contract_group = $_[1];
        });
    BOM::Config::RedisReplicated::redis_limits_write->hget(
        'UNDERLYINGGROUPS',
        $underlying,
        sub {
            $underlying_group = $_[1];
        });
    BOM::Config::RedisReplicated::redis_limits_write->mainloop;

    # print 'BET DATA: ', Dumper($contract);
    my @combinations = _get_combinations($contract, $underlying_group, $contract_group);
    # print 'COMBINATIONS:', Dumper(\@combinations);

    # GET LIMITS!!
    my $limits_response = BOM::Config::RedisReplicated::redis_limits_write->hmget('LIMITS', @combinations);

    my %limits;
    foreach my $i (0 .. scalar @combinations) {
        if ($limits_response->[$i]) {
            $limits{$combinations[$i]} = $limits_response->[$i];
        }
    }

    print 'LIMITS:', Dumper(\%limits);

    my %totals = limits_to_totals(%limits, $underlying_group);
    print 'totals:', Dumper(\%totals);

    # INCREMENTS!!!

}

sub limits_to_totals {
    my (%limits, $underlying_group) = @_;
    my %totals;

    # The loop here makes the assumption that underlying group limits
    # all procede underlying limits.
    while(my($k, $v) = each %limits) {
        # for each array ref, allocate exactly 2 elements in order: potential,
        # realized loss
        # Potential #1 and Realized #1 are the actual limits for the totals
        $totals{$k} = [$v->[0], $v->[2]];

        # Assume that if Potential #2 or Realized #2 is set, it is underlying
        # group defaults limit:

    }

    return %totals;
}


sub _get_combinations {
    my ($contract, $underlying_group, $contract_group) = @_;
    my $bet_data = $contract->{bet_data};
    my $underlying = $bet_data->{underlying_symbol};

    # print "CONTRACT GROUP: $contract_group\nUNDERLYING GROUP: $underlying_group\n";

    my $is_atm = ($bet_data->{short_code} =~ /_SOP_/) ? 't' : 'f';

    my $expiry_type;
    if ($bet_data->{tick_count} and $bet_data->{tick_count} > 0) {
        $expiry_type = 'tick';
    } elsif ($bet_data->{expiry_daily}) {
        $expiry_type = 'daily';
    } elsif ((Date::Utility->new($bet_data->{expiry_time})->epoch - Date::Utility->new($bet_data->{start_time})->epoch) <= 300) {    # 5 minutes
        $expiry_type = 'ultra_short';
    } else {
        $expiry_type = 'intraday';
    }

    my @attributes = ($underlying, $contract_group, $expiry_type, $is_atm);
    my @combinations = BOM::CompanyLimits::Helpers::get_all_key_combinations(@attributes);

    # Merge another array that substitutes underlying with underlying group
    my @underlyinggroup_combinations = grep(/^${underlying}\,/, @combinations);
    foreach my $x (@underlyinggroup_combinations) {
        substr($x, 0, length($underlying)) = $underlying_group;
    }

    return (@combinations, @underlyinggroup_combinations);
}

1;

