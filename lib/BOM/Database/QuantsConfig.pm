package BOM::Database::QuantsConfig;

=head NAME

BOM::Database::QuantsConfig - a class to get and set quants global limits

=head DESCRIPTION

    use BOM::Database::QuantsConfig;

    my $qc = BOM::Database::QuantsConfig->new;

    # get limits
    my $all_limits = $qc->get_all_global_limit(['costarica', 'malta']);
    my $specific_limits = $qc->get_global_limit({market => 'forex', limit_type => 'global_potential_loss'});

    # set limits
    $qc->set_global_limit({
        market => ['forex'],
        underlying_symbol => ['frxUSDJPY'. 'frxAUDJPY'],
        barrier_category => ['atm'],
        limit_type => 'global_potential_loss',
        limit_amount => 10000
    });

=cut

use strict;
use warnings;

use Moo;

use BOM::Database::ClientDB;

use Digest::MD5 qw(md5_hex);
use Scalar::Util qw(looks_like_number);
use List::Util qw(uniq);
use List::MoreUtils qw(all);
use LandingCompany::Registry;
use YAML::XS qw(LoadFile);
use Finance::Underlying;

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
            costarica   => 1,
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
        # the idea is to map the first broker code from the first landing company list which connect to the same client database.
        my $broker_code;
        foreach my $lc_name (@$lc_list) {
            my $lc = LandingCompany::Registry::get($lc_name) or next;
            $broker_code //= $lc->{broker_codes}->[0];
            last if $broker_code;
        }
        $map{$_} = $broker_code for @$lc_list;
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

    for (qw(limit_type limit_amount)) {
        die "$_ not specified" unless defined $args->{$_};
    }

    my $supported_config = $self->supported_config_type->{per_landing_company};

    die 'limit_type is not supported' unless $supported_config->{$args->{limit_type}};

    die "limit_amount must be a positive number" if not looks_like_number($args->{limit_amount}) or $args->{limit_amount} < 0;

    if (    $args->{market}
        and scalar(@{$args->{market}}) > 1
        and @{$args->{underlying_symbol}}
        and (scalar(@{$args->{underlying_symbol}}) > 1 or grep { $_ ne 'default' } @{$args->{underlying_symbol}}))
    {
        die "If you select multiple markets, underlying symbol can only be default";
    }

    if (@{$args->{underlying_symbol}}) {
        # if underlying symbol is specified, then market is required
        die "Please specify the market of the underlying symbol input" unless $args->{market};
        # must be default or a valid underlying symbol
        die "invalid underlying symbol"
            if grep { $_ ne 'default' and not Finance::Underlying->by_symbol($_) } @{$args->{underlying_symbol}};
    }

    my $statement;
    if (@{$args->{underlying_symbol}}) {
        my $table_name = 'update_symbol_' . $args->{limit_type};
        $statement = qq{SELECT betonmarkets.$table_name (?,?,?,?,?,?)};
    } else {
        my $table_name = 'update_market_' . $args->{limit_type};
        $statement = qq{SELECT betonmarkets.$table_name (?,?,?,?,?)};
    }

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
                            if (@{$args->{underlying_symbol}}) {
                                foreach my $u_symbol (@{$args->{underlying_symbol}}) {
                                    my $query_symbol = $u_symbol;
                                    $query_symbol = undef if $u_symbol and $u_symbol eq 'default';
                                    $self->_update_db($db, $statement,
                                        [$market, $query_symbol, $contract_group, $expiry_type, $barrier_type, $args->{limit_amount}]);
                                }
                            } else {
                                $self->_update_db($db, $statement, [$market, $contract_group, $expiry_type, $barrier_type, $args->{limit_amount}]);
                            }
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
    market => 'forex',
    limit_type => 'global_potential_loss',
    landing_company => 'costarica',
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

    my $amount = $db->dbic->run(
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
            my $limit;
            if ($record) {
                ($limit) = $record =~ /^\(\d+,(\d+)\)$/;
            }
            return $limit;
        });

    return $amount;
}

=head2 get_all_global_limit

Get all global limits for a landing company

->get_all_global_limit(['default']); # all landing company
->get_all_global_limit(['costarica']); # costarica specific limits

=cut

sub get_all_global_limit {
    my ($self, $landing_company) = @_;

    # if there's a default, override the whole list
    if (grep { $_ eq 'default' } @$landing_company) {
        $landing_company = [keys %{$self->broker_code_mapper}];
    }

    my %limits = map { my $l = $self->_get_all($_); defined $l ? ($_ => $l) : () } @$landing_company;

    my @all_ids = uniq map { keys %{$limits{$_}} } keys %limits;
    # fill the landing_company field for each record.
    foreach my $id (@all_ids) {
        if (all { $limits{$_}{$id} } @$landing_company) {
            $limits{$_}{$id}{landing_company} = 'default' for @$landing_company;
        } else {
            for (grep { $limits{$_}{$id} } @$landing_company) {
                $limits{$_}{$id}{landing_company} = $_;
            }
        }
    }

    my @records = values %limits;
    my %uniq_records = map { %{$records[$_]} } (0 .. $#records);

    return [values %uniq_records];
}

# This as a separate funtion is purely for testability.
# Currently, we only have one client database in development environment.
sub _get_all {
    my ($self, $landing_company) = @_;

    my %limits;
    foreach my $db (@{$self->_db_list($landing_company)}) {
        foreach my $limit_type (sort keys %{$self->supported_config_type->{per_landing_company}}) {
            foreach my $data (
                ['market_' . $limit_type,                      [qw(market contract_group expiry_type barrier_type)],            'market'],
                ['symbol_' . $limit_type,                      [qw(underlying_symbol contract_group expiry_type barrier_type)], 'symbol'],
                ['symbol_' . $limit_type . '_market_defaults', [qw(market contract_group expiry_type barrier_type)],            'symbol_default'],
                )
            {
                my ($table_name, $table_fields, $type) = @$data;
                my $id_postfix = $type =~ /^symbol/ ? 'symbol' : 'market';
                my $records = $db->dbic->run(
                    fixup => sub {
                        $_->selectall_arrayref(qq{SELECT * from betonmarkets.$table_name});
                    });
                foreach my $record (@$records) {
                    my $limit_amount = pop @$record;
                    my $id = substr(md5_hex(join '', @$record, $id_postfix), 0, 16);
                    for (0 .. $#$record) {
                        my $name = $table_fields->[$_];
                        my $name_info = $record->[$_] ? $record->[$_] : 'default';
                        if ($name eq 'barrier_type' and $name_info ne 'default') {
                            $name_info = $name_info eq 'true' ? 'atm' : 'non_atm';
                        }
                        $limits{$id}{$name} = $name_info;
                    }
                    # for market level, underlying symbol is '-'
                    $limits{$id}{underlying_symbol} //= ($type eq 'symbol_default' ? 'default' : '-');
                    $limits{$id}{market} //= $self->_get_market_for_symbol($limits{$id}{underlying_symbol});
                    $limits{$id}{$limit_type} = $limit_amount;
                    $limits{$id}{type} = $type;
                }
            }
        }
    }

    return \%limits;
}

=head2 delete_global_limit

get global limits with parameters. Valid parameters:
- expiry_type (defaults to undef)
- barrier_type (defaults to undef)
- contract_group (defaults to undef)
- underlying_symbol (defaults to undef)
- market (defaults to undef)
- landing_company (required)
- limit_type (required)

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
        $statement   = qq{SELECT betonmarkets.$table_name (?,?,?,?,?)};
        @func_inputs = qw(market contract_group expiry_type barrier_type);
    } else {
        my $table_name = 'update_symbol_' . $args->{limit_type};
        $statement   = qq{SELECT betonmarkets.$table_name (?,?,?,?,?,?)};
        @func_inputs = qw(market underlying_symbol contract_group expiry_type barrier_type);
    }

    foreach my $db (@{$self->_db_list($landing_company)}) {
        my @execute_args;
        foreach my $key (@func_inputs) {
            my $val = $args->{$key};
            $val = undef if $val and $val eq 'default';
            $val = $val eq 'atm' ? 1 : 0 if $key eq 'barrier_type' and defined $val;
            push @execute_args, $val;
        }
        my $limit_amount = undef;
        push @execute_args, $limit_amount;    # to delete
        $self->_update_db($db, $statement, \@execute_args);
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
