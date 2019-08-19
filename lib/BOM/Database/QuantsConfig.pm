package BOM::Database::QuantsConfig;

=head NAME

BOM::Database::QuantsConfig - a class to get and set quants global limits

=head DESCRIPTION

    use BOM::Database::QuantsConfig;

    my $qc = BOM::Database::QuantsConfig->new;

    # get limits
    my $all_limits = $qc->get_all_global_limit(['svg', 'malta']);
    my $specific_limits = $qc->get_global_limit({market => 'forex', limit_type => 'global_potential_loss'});

    # set limits
    $qc->set_global_limit({
        market => ['forex'],
        underlying_symbol => ['frxUSDJPY'. 'frxAUDJPY'],
        barrier_category => ['atm'],
        limit_type => 'global_potential_loss',
        limit_amount => 10000,
    });

    # set a time-restricted limit
    $qc->set_global_limit({
        market => ['forex'],
        limit_type => 'global_potential_loss',
        limit_amount => 1000,
        start_time => '2019-11-05 09:00',
        end_time => '2019-11-05 17:00'
        comment => 'Added by Alice to handle Guy Fawkes Day',
    });

=cut

use strict;
use warnings;

use Moo;

use Digest::MD5 qw(md5_hex);
use Scalar::Util qw(looks_like_number);
use List::Util qw(uniq all);
use YAML::XS qw(LoadFile);
use Finance::Underlying;
use Try::Tiny;

use LandingCompany::Registry;

use BOM::Database::ClientDB;
my $clientdb_config = LoadFile('/etc/rmg/clientdb.yml');

=head2 supported_config_type

Returns a hash reference of supported config type.

Currently, we only have landing company specific config.
If it works well, we will have client specific config in the future.

=cut

sub supported_config_type {
    return {
        per_landing_company => {
            global_potential_loss => 'Global Potential Loss',
            global_realized_loss  => 'Global Realized Loss',
        },
        per_user => {
            user_potential_loss => 'User Potential Loss',
            user_realized_loss  => 'User Realized Loss',
        },
        # TODO: include per client quants config in the next phase.
        # This would also clean up RiskProfile. Basically, we will remove static profile setting and have profiles listed all in one place
        per_client => {},
    };
}

=head2 broker_code_mapper

A landing company to broker code mapper.

=cut

has active_landing_company => (
    is      => 'ro',
    default => sub {
        {
            svg         => 1,
            iom         => 1,
            malta       => 1,
            maltainvest => 1,
        };
    });

has broker_code_mapper => (is => 'lazy');

sub _build_broker_code_mapper {
    my $self = shift;

    my %list_by_dbname;
    foreach my $short (grep { $self->active_landing_company->{$_} } keys %$clientdb_config) {
        my $write_info = $clientdb_config->{$short}{write};
        push @{$list_by_dbname{$write_info->{name}}}, $short;
    }
    my %map;
    foreach my $lc_list (values %list_by_dbname) {
        foreach my $lc_name (@$lc_list) {
            my $lc = LandingCompany::Registry::get($lc_name) or next;

            my $broker_code = $lc->{broker_codes}->[0];
            $map{$lc_name} = $broker_code if $broker_code;
        }
    }
    return \%map;
}

=head2 set_global_limit

set global limits with parameters. Valid parameters:
- expiry_type (defaults to undef)
- barrier_type (defaults to undef)
- contract_group (defaults to undef)
- underlying_symbol (defaults to undef)
- market (defaults to undef)
- landing_company (defaults to all landing company)
- limit_type (required)
- limit_amount (required)
- comment (optional)
- start_time (timestamp, optional)
- end_time (timestamp, optional)

->set_global_limit({
    market => ['forex'],
    limit_type => 'global_potential_loss',
    limit_amount => 1000,
});

=cut

sub set_global_limit {
    my ($self, $args) = @_;

    $args->{$_} //= [undef] for qw(expiry_type barrier_type contract_group);
    # default to empty array reference if not set
    $args->{underlying_symbol} //= [];
    # only set default market if underlying symbol is not specified
    $args->{market} //= [undef] unless @{$args->{underlying_symbol}};
    # set it to default
    $args->{landing_company} //= ['default'];

    die "Please specify a limit amount\n" unless defined $args->{limit_amount};

    die "Please specify a limit type\n" unless defined $args->{limit_type};

    my $supported_config = $self->supported_config_type->{per_landing_company};

    die "Limit type is not supported\n" unless $supported_config->{$args->{limit_type}};

    die "Limit amount must be a positive number\n" if not looks_like_number($args->{limit_amount}) or $args->{limit_amount} < 0;

    if (    $args->{market}
        and scalar(@{$args->{market}}) > 1
        and @{$args->{underlying_symbol}}
        and (scalar(@{$args->{underlying_symbol}}) > 1 or grep { $_ ne 'default' } @{$args->{underlying_symbol}}))
    {
        die "If you select multiple markets, underlying symbol can only be default\n";
    }

    if (@{$args->{underlying_symbol}}) {
        # if underlying symbol is specified, then market is required
        die "Please specify the market of the underlying symbol input\n" unless $args->{market};
        # must be default or a valid underlying symbol
        die "Invalid underlying symbol\n"
            if grep { $_ ne 'default' and not Finance::Underlying->by_symbol($_) } @{$args->{underlying_symbol}};
    }

    if (defined $args->{start_time} and not defined $args->{end_time}) {
        die "If using start time, must also provide end time\n";
    }
    if (defined $args->{end_time} and not defined $args->{start_time}) {
        die "If using end time, must also provide start time\n";
    }

    ## Clean up and verify the start and end times
    if (defined $args->{start_time}) {
        for my $time (qw/ start_time end_time /) {

            ## Change any odd characters (e.g. tabs) to spaces and collapse them
            $args->{$time} =~ s/[^\d\-\:\w]+/ /g;

            ## Remove whitespace
            $args->{$time} =~ s/^\s*(.+?)\s*$/$1/;

            ## If this looks like just a date, adjust to start or end of day
            ## Example: "2018-07-04" becomes "2018-07-04 00:00:00"
            if ($args->{$time} =~ /^\d\d\d\d\-\d\d?\-\d\d?$/) {
                $args->{$time} .= $time eq 'start_time' ? ' 00:00:00' : ' 24:00:00';
            } else {
                ## Turn four and six digit numbers into proper times
                ## Example: "1234" becomes "12:34:00"
                ## Example: "102101" becomes "10:21:01"
                $args->{$time} =~ s/^(\d\d)(\d\d)$/$1:$2:00/;
                $args->{$time} =~ s/^(\d\d)(\d\d)(\d\d)$/$1:$2:$3/;

                ## If we only have a single number, assume it is an hour and add the minutes
                ## Example "12" becomes "12:00:00"
                $args->{$time} =~ s/^(\d\d?)$/$1:00:00/;

                ## Same as above, but with the year
                ## Example "2018-11-28 12" becomes "2018-11-28 12:00:00"
                $args->{$time} =~ s/^(\d\d\d\d\-\d\d?\-\d\d? \d\d?)$/$1:00:00/;

                ## If we just have a time, add today's date
                ## Example: "12:00" becomes "today 12:00"
                if ($args->{$time} =~ /^\s*\d[\d:]{0,7}\s*$/) {
                    $args->{$time} = "today $args->{$time}";
                }
            }
        }

        ## Quick sanity check, but the database will also catch similar cases
        if ($args->{start_time} eq $args->{end_time}) {
            die "The start_time and end_time may not be the same\n";
        }
    }

    my $statement;
    if (@{$args->{underlying_symbol}}) {
        my $table_name = 'update_symbol_' . $args->{limit_type};
        $statement = qq{SELECT betonmarkets.$table_name (?,?,?,?,?,?, ?,?,?)};
    } else {
        my $table_name = 'update_market_' . $args->{limit_type};
        $statement = qq{SELECT betonmarkets.$table_name (?,?,?,?,?, ?,?,?)};
    }

    my $comment = $args->{comment} // '';
    foreach my $lc (@{$args->{landing_company}}) {
        foreach my $db (@{$self->_db_list($lc)}) {
            foreach my $market (@{$args->{market}}) {
                foreach my $expiry_type (@{$args->{expiry_type}}) {
                    foreach my $bt (@{$args->{barrier_type}}) {
                        my $barrier_type;
                        if ($bt) {
                            $barrier_type = $bt eq 'atm' ? 1 : 0;
                        }
                        foreach my $contract_group (@{$args->{contract_group}}) {
                            try {
                                if (@{$args->{underlying_symbol}}) {
                                    foreach my $u_symbol (@{$args->{underlying_symbol}}) {
                                        my $query_symbol = $u_symbol;
                                        $query_symbol = undef if $u_symbol and $u_symbol eq 'default';
                                        $self->_update_db(
                                            $db,
                                            $statement,
                                            [
                                                $market,      $query_symbol,       $contract_group,
                                                $expiry_type, $barrier_type,       $args->{limit_amount},
                                                $comment,     $args->{start_time}, $args->{end_time}]);
                                    }
                                } else {
                                    $self->_update_db(
                                        $db,
                                        $statement,
                                        [
                                            $market,               $contract_group, $expiry_type,        $barrier_type,
                                            $args->{limit_amount}, $comment,        $args->{start_time}, $args->{end_time}]);
                                }
                            }
                            catch {
                                if ($_) {
                                    ## Catch known date/time errors
                                    if ($_ =~ /field value out of range|invalid input syntax/) {
                                        die "Sorry, that is not a valid time.\n";
                                    }
                                    die $_;
                                }
                            };
                        }
                    }
                }
            }
        }
    }

    return;
}

=head2 get_global_limit

get global limits with parameters. Valid parameters:
- expiry_type (defaults to undef)
- barrier_type (defaults to undef)
- contract_group (defaults to undef)
- underlying_symbol (defaults to undef)
- market (defaults to undef)
- landing_company (required)
- limit_type (required)

    ->get_global_limit({
        underlying_symbol => 'default',
        market            => 'forex',
        limit_type        => 'global_potential_loss',
        landing_company   => 'svg',
    });

=cut

sub get_global_limit {

    my ($self, $args) = @_;

    my $landing_company = $args->{landing_company};
    my $lt              = $args->{limit_type};
    die 'landing_company is undefined'                  unless $landing_company;
    die 'limit_type is undefined'                       unless $lt;
    die 'unsupported limit type ' . $args->{limit_type} unless $self->supported_config_type->{per_landing_company}{$lt};

    my $table_name = 'get_market_' . $lt;
    my $statement  = qq{SELECT betonmarkets.$table_name (?,?,?,?)};
    my @key_list   = qw(market contract_group expiry_type barrier_type);
    if (my $us = $args->{underlying_symbol}) {
        $table_name = 'get_symbol_' . $lt;
        $statement  = qq{SELECT betonmarkets.$table_name (?,?,?,?,?)};
        @key_list   = qw(market underlying_symbol contract_group expiry_type barrier_type);
    }

    my $db_list = $self->_db_list($landing_company);
    my $db = @$db_list ? $db_list->[0] : undef;

    die 'cannot find database for landing company [' . $landing_company . ']' unless $db;

    my $row = $db->dbic->run(
        fixup => sub {
            my @execute_args;
            foreach my $key (@key_list) {
                my $val = $args->{$key};
                $val = $val eq 'atm' ? 1 : 0 if $key eq 'barrier_type' and defined $val;
                $val = undef if $key eq 'underlying_symbol' and $val and $val eq 'default';
                push @execute_args, $val;
            }
            my $sth = $_->prepare($statement);
            $sth->execute(@execute_args);
            my $output = $sth->fetchrow_arrayref();
            my $record = @$output ? $output->[0] : undef;
            return $record;
        });

    return undef if !defined $row;
    my ($rank, $limit) = split /,/ => $row;
    return $limit;
}

=head2 get_all_global_limit

Get all global limits for a landing company

->get_all_global_limit(['default']); # all landing company
->get_all_global_limit(['svg']); # svg specific limits

=cut

sub get_all_global_limit {
    my ($self, $landing_company) = @_;

    # if there's a default, override the whole list
    if (grep { $_ eq 'default' } @$landing_company) {
        $landing_company = [keys %{$self->broker_code_mapper}];
    }

    my %limits = map { my $l = $self->_get_all($_); defined $l ? ($_ => $l) : () } @$landing_company;

    return $self->_get_unique_records(\%limits, $landing_company);
}

sub _get_unique_records {
    my ($self, $data, $landing_company) = @_;

    my @all_ids = uniq map { keys %{$data->{$_}} } keys %$data;
    # fill the landing_company field for each record.
    foreach my $id (@all_ids) {
        if (all { $data->{$_}{$id} } @$landing_company) {
            $data->{$_}{$id}{landing_company} = 'default' for @$landing_company;
        } else {
            for (grep { $data->{$_}{$id} } @$landing_company) {
                $data->{$_}{$id}{landing_company} = $_;
            }
        }
    }

    my @records = values %$data;
    my %uniq_records = map { %{$records[$_]} } (0 .. $#records);

    return [values %uniq_records];
}

# This as a separate function is purely for testability.
# Currently, we only have one client database in development environment.
sub _get_all {
    my ($self, $landing_company) = @_;

    my $time_status =
          'CASE WHEN end_time IS NOT NULL AND end_time < now() THEN 3 '
        . 'WHEN start_time IS NOT NULL AND start_time < now() AND end_time > now() THEN 2 '
        . 'ELSE 1 END AS time_status';
    my %limits;
    foreach my $db (@{$self->_db_list($landing_company)}) {
        foreach my $limit_type (sort keys %{$self->supported_config_type->{per_landing_company}}) {
            foreach my $data (
                ['market_' . $limit_type,                      'market'],
                ['symbol_' . $limit_type,                      'symbol'],
                ['symbol_' . $limit_type . '_market_defaults', 'symbol_default'],
                )
            {
                my ($table_name, $type) = @$data;
                my $id_postfix = $type =~ /^symbol/ ? 'symbol' : 'market';
                my $records = $db->dbic->run(
                    fixup => sub {
                        $_->selectall_arrayref(qq{SELECT *, $time_status FROM betonmarkets.$table_name}, {Slice => {}});
                    });
                foreach my $record (@$records) {
                    my $id = substr(md5_hex(join '', sort map { $_ // 'undef' } values %$record, $id_postfix), 0, 16);
                    for my $name (keys %$record) {
                        my $name_info = $record->{$name} || 'default';

                        ## We only want to show up to the second granularity for start_time and end_time
                        if ($name =~ /_time$/ and $name_info ne 'default') {
                            $name_info =~ s/(\d\d\d\d-\d\d-\d\d \d\d:\d\d\:\d\d).+/$1/;
                        }

                        # barrier_type is linked to the 'is_atm' column
                        if ($name eq 'is_atm') {
                            $name = 'barrier_type';
                            if ($name_info ne 'default') {
                                $name_info = $name_info eq 'true' ? 'atm' : 'non_atm';
                            }
                        }

                        ## We want to refer to 'symbol' as 'underlying_symbol' henceforth
                        $name = 'underlying_symbol' if $name eq 'symbol';

                        $limits{$id}{$name} = $name_info;
                    }

                    # for market level, underlying symbol is '-'
                    $limits{$id}{underlying_symbol} //= ($type eq 'symbol_default' ? 'default' : '-');
                    $limits{$id}{market} //= $self->_get_market_for_symbol($limits{$id}{underlying_symbol});
                    $limits{$id}{$limit_type} = $record->{limit_amount};
                    $limits{$id}{type} = $type;
                }
            }
        }
    }

    return \%limits;
}

=head2 delete_market_group

delete global limits with parameters. Valid parameters:
- symbol (required)
- market (required)
- landing_company (required)
- start_time (required)
- end_time (required)

->delete_market_group({
    market => 'new_forex',
    landing_company => 'default',
    start_time => time,
    end_time => time + 300,
    symbol => 'frxAUDJPY,frxEURJPY',
})
=cut

sub delete_market_group {
    my ($self, $args) = @_;

    $args->{symbol} =~ s/\s+//g;

    my $statement = qq{SELECT betonmarkets.delete_quants_wishlist(?,?,?,?)};
    foreach my $db (@{$self->_db_list($args->{landing_company})}) {
        foreach my $symbol (split ',', $args->{symbol}) {
            my @execute_args = ($args->{market}, $symbol, Date::Utility->new($args->{start_time})->db_timestamp,
                Date::Utility->new($args->{end_time})->db_timestamp);
            $self->_update_db($db, $statement, \@execute_args);
        }
    }

    return;
}

=head2 delete_global_limit

delete global limits with parameters. Valid parameters:
- expiry_type (defaults to undef)
- barrier_type (defaults to undef)
- contract_group (defaults to undef)
- underlying_symbol (defaults to undef)
- market (defaults to undef)
- landing_company (required)
- limit_type (required)
- start_time (optional)
- end_time (otional)

->delete_global_limit({
    market => ['forex'],
    limit_type => 'global_potential_loss'
})

=cut

sub delete_global_limit {
    my ($self, $args) = @_;

    my $type            = delete $args->{type};
    my $landing_company = delete $args->{landing_company};
    my $statement;
    my @func_inputs;

    if ($type eq 'market') {
        my $table_name = 'update_market_' . $args->{limit_type};
        $statement   = qq{SELECT betonmarkets.$table_name (?,?,?,?,?, ?,?,?)};
        @func_inputs = qw(market contract_group expiry_type barrier_type limit   comment start_time end_time);
    } else {
        my $table_name = 'update_symbol_' . $args->{limit_type};
        $statement   = qq{SELECT betonmarkets.$table_name (?,?,?,?,?,?, ?,?,?)};
        @func_inputs = qw(market underlying_symbol contract_group expiry_type barrier_type limit   comment start_time end_time);
    }

    foreach my $db (@{$self->_db_list($landing_company)}) {
        my @execute_args;
        foreach my $key (@func_inputs) {
            my $val = $args->{$key};
            $val = undef if $val and $val eq 'default';
            $val = $val eq 'atm' ? 1 : 0 if $key eq 'barrier_type' and defined $val;
            $val = undef if $key eq 'limit';    ## We delete by providing a null limit amount
            push @execute_args, $val;
        }
        $self->_update_db($db, $statement, \@execute_args);
    }

    return;
}

sub set_pending_market_group {
    my ($self, $args) = @_;

    my ($landing_company, $new_market, $symbols, $start, $end) = @{$args}{qw(landing_company new_market symbols start_time end_time)};
    $landing_company //= 'default';

    my $statement = qq{SELECT betonmarkets.insert_quants_wishlist(?,?,?,?)};
    foreach my $db (@{$self->_db_list($landing_company)}) {
        foreach my $symbol (@$symbols) {
            $self->_update_db($db, $statement, [$new_market, $symbol, $start, $end]);
        }
    }

    return;
}

sub get_pending_market_group {
    my ($self, $landing_company) = @_;

    # if there's a default, override the whole list
    if (grep { $_ eq 'default' } @$landing_company) {
        $landing_company = [keys %{$self->broker_code_mapper}];
    }

    my %pending_groups = map { my $l = $self->_get_all_pending($_); defined $l ? ($_ => $l) : () } @$landing_company;

    return $self->_get_unique_records(\%pending_groups, $landing_company);
}

sub _get_all_pending {
    my ($self, $landing_company) = @_;

    my $pending_groups;
    foreach my $db (@{$self->_db_list($landing_company)}) {
        $db->dbic->run(
            fixup => sub {
                my @records = @{$_->selectall_arrayref("SELECT * FROM betonmarkets.quants_wishlist;", {Slice => {}}) // []};
                foreach my $record (@records) {
                    my $id = substr(md5_hex(join('', map { $record->{$_} } sort keys %$record)), 0, 16);
                    $pending_groups->{$id} = $record;
                }
            });
    }

    return $pending_groups;
}

=head2 cleanup_expired_quants_config

Cleans up expired quants config.

This is invoked by a cron running every minute..

=cut

sub cleanup_expired_quants_config {
    my $self = shift;

    foreach my $db (@{$self->_db_list('default')}) {
        $db->dbic->run(
            fixup => sub {
                $_->do("SELECT betonmarkets.cleanup_expired_quants_config()");
            });
    }

    return;
}

=head2 switch_pending_market_group

This function handles switching between pending market group for a list of underlyings
and also reverses the change once the time period is over.

This is invoked by a cron running every minute..

=cut

sub switch_pending_market_group {
    my $self = shift;

    foreach my $db (@{$self->_db_list('default')}) {
        $db->dbic->run(
            fixup => sub {
                $_->do("SELECT betonmarkets.switch_market_pending_group()");
            });
    }

    return;
}

=head2 update_market_group

Update bet.limits_market_mapper table for underlying with the right information.
->update_market_group({
    underlying_symbol => 'frxUSDJPY',
    market => 'new_market',
})

=cut

sub update_market_group {
    my ($self, $args) = @_;

    foreach my $db (@{$self->_db_list('default')}) {
        foreach my $underlying_symbol (split ',', $args->{underlying_symbol}) {
            my $u_config = Finance::Underlying->by_symbol($underlying_symbol);
            $args->{submarket_group} //= $u_config->{submarket};
            $args->{market_type}     //= $u_config->{market_type};
            $args->{market_group} = $u_config->{market} if $args->{market_group} eq 'default';
            $db->dbic->run(
                fixup => sub {
                    $_->do(
                        qq{SELECT bet.update_underlying_symbol_group(?,?,?,?)},
                        undef, $underlying_symbol, $args->{market_group}, $args->{submarket_group},
                        $args->{market_type});
                },
            );

        }
    }

    return;
}

### PRIVATE ###

sub _update_db {
    my ($self, $db, $statement, $args) = @_;

    $db->dbic->run(
        fixup => sub {
            my $sth = $_->prepare($statement);
            $sth->execute(@$args);
        });

    return;
}

sub _get_market_for_symbol {
    my ($self, $underlying_symbol) = @_;

    return '-' if $underlying_symbol eq '-' or $underlying_symbol eq 'default';
    my $underlying_config = Finance::Underlying->by_symbol($underlying_symbol);
    die 'unknown underlying [' . $underlying_symbol . ']' unless $underlying_config;
    return $underlying_config->market;
}

sub _db_list {
    my ($self, $landing_company) = @_;

    my $mapper = $self->broker_code_mapper;
    my @broker_codes = $landing_company eq 'default' ? uniq(values %$mapper) : ($mapper->{$landing_company});
    return [map { BOM::Database::ClientDB->new({broker_code => $_,})->db } @broker_codes];
}

1;
