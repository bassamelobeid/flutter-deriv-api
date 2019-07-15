package BOM::CompanyLimits;
use strict;
use warnings;

use BOM::Database::ClientDB;
use BOM::Config::RedisReplicated;
use Date::Utility;
use Data::Dumper;

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
    my ($self, $bet_data) = @_;
    my $b_data = $bet_data->{bet_data};

    my $is_atm = ($b_data->{short_code} =~ /_SOP_/) ? 't' : 'f';

    my $expiry_type;
    if ($b_data->{tick_count} > 0) {
        $expiry_type = 'tick';
    } elsif ($b_data->{expiry_daily}) {
        $expiry_type = 'daily';
    } elsif ((Date::Utility->new($b_data->{expiry_time})->epoch - Date::Utility->new($b_data->{start_time})->epoch) <= 300) {    # 5 minutes
        $expiry_type = 'ultra_short';
    } else {
        $expiry_type = 'intraday';
    }

    # my @key_combinations = ($b_data->{underlying_symbol}, $b_data->
}

