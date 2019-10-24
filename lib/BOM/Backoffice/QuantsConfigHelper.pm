package BOM::Backoffice::QuantsConfigHelper;

use strict;
use warnings;

use BOM::Database::QuantsConfig;
use BOM::Database::ClientDB;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;

use Finance::Underlying;
use LandingCompany::Registry;
use Finance::Contract::Category;
use Try::Tiny;
use YAML::XS qw(LoadFile);
use List::Util qw(uniq);
use BOM::Backoffice::Auth0;
use BOM::Backoffice::QuantsAuditLog;
use Time::Duration::Concise;

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

sub save_limit {
    my $args  = shift;
    my $staff = shift;

    for my $key (keys %$args) {
        next if !defined $args->{$key};
        if ($key =~ /comment|start_time|end_time/) {
            $args->{$key} =~ s/^\s*(.*?)\s*$/$1/;
        } else {
            $args->{$key} =~ s/\s+//g;
        }
    }

    # clean up and restructure inputs
    my %new_args = map {
              ($_ =~ /new_market|limit_type|limit_amount|comment|start_time|end_time/) ? ($_ => $args->{$_})
            : ($_ =~ /underlying_symbol/) ? ($_ => [split ',', $args->{$_}])
            : ($_ => [$args->{$_} =~ /$_=(\w+)/g])
        } grep {
        defined $args->{$_} and $args->{$_} ne ''
        } keys %$args;

    my $limits = try {
        my $qc = BOM::Database::QuantsConfig->new();
        # if the specified market group is not currently tied to any underlying symbol and we have a selected time period defined,
        # then we need to store these information into another table.
        die 'market and new_market cannot co-exists' if $new_args{market} and $new_args{new_market};
        if ($new_args{underlying_symbol} and $new_args{new_market}) {
            # delete $new_args{underlying_symbol} from %new_args because we will then save this entry as a market level limit.
            my $symbols_to_alter = delete $new_args{underlying_symbol};
            $new_args{market} = [$new_args{new_market}];
            die 'start_time and end_time are required when setting new market group for underlyings'
                unless $new_args{start_time} and $new_args{end_time};
            $qc->set_pending_market_group({
                    landing_company => $new_args{landing_company},
                    new_market      => $new_args{new_market},
                    symbols         => $symbols_to_alter,
                    start_time      => $new_args{start_time},
                    end_time        => $new_args{end_time}});
        }

        $qc->set_global_limit(\%new_args);

        my $args_content = join(q{, }, map { qq{$_ => $args->{$_}} } keys %{$args});
        BOM::Backoffice::QuantsAuditLog::log($staff, "setnewgloballimit", $args_content);

        my $decorated_limit = decorate_for_display($qc->get_all_global_limit(['default']));
        my $pending_group   = decorate_for_pending_market_group($qc->get_pending_market_group(['default']));
        +{
            limit        => $decorated_limit,
            market_group => $pending_group,
        };

    }
    catch {
        my $error = ref $_ eq 'Mojo::Exception' ? $_->message : $_;
        ## Postgres error messages are too verbose to show the whole thing:
        $error =~ s/(DETAIL|CONTEXT|HINT):.*//s;
        +{error => $error};
    };

    return $limits;
}

sub delete_limit {
    my $args  = shift;
    my $staff = shift;

    my $deleted = 0;

    my $limits = try {
        my $qc             = BOM::Database::QuantsConfig->new();
        my $decorated_data = decorate_for_display($qc->get_all_global_limit(['default']));
        my $records_len    = scalar(@{$decorated_data->{records}});

        $qc->delete_global_limit($args);

        $decorated_data = decorate_for_display($qc->get_all_global_limit(['default']));

        $deleted = $records_len - scalar(@{$decorated_data->{records}});

        +{
            data    => $decorated_data,
            deleted => $deleted
        };
    }
    catch {
        +{error => $_};
    };

    my $args_content = join(q{, }, map { qq{$_ => $args->{$_}} } keys %$args);
    BOM::Backoffice::QuantsAuditLog::log($staff, "deletegloballimit", $args_content);

    return $limits;
}

sub update_contract_group {
    my $args = shift;

    $args->{contract_type} =~ s/\s+//g;
    my $contract_types = $args->{contract_type};
    my $contract_group = $args->{contract_group};
    my $duration       = $app_config->quants->ultra_short_duration;

    my $output = try {
        my $dbs = BOM::Database::QuantsConfig->new->_db_list('default');
        foreach my $db (@$dbs) {
            my $dbic = $db->dbic;
            foreach my $contract_type (split ',', $contract_types) {
                if ($contract_group eq 'default') {
                    $contract_group = Finance::Contract::Category::get_all_contract_types()->{$contract_type}{category};
                }
                $dbic->run(
                    ping => sub {
                        $_->do(qq{SELECT bet.update_contract_group(?,?,?)}, undef, $contract_type, $contract_group, $duration);
                    },
                );
            }
        }
        +{success => 1};
    }
    catch {
        my $error = {error => 'Error while updating contract group'};
        warn 'Exception thrown while updating contract group: ' . $_;
        $error;
    };

    return $output;
}

sub rebuild_aggregate_tables {

    my $duration = shift // $app_config->quants->ultra_short_duration;

    my $output = try {
        foreach my $method (qw(rebuild_open_contract_aggregates rebuild_global_aggregates)) {
            my $dbs = BOM::Database::QuantsConfig->new->_db_list('default');
            foreach my $db (@$dbs) {
                my $dbic = $db->dbic;
                $dbic->run(
                    ping => sub {
                        $_->do(qq{SELECT bet.$method(?)}, undef, $duration);
                    },
                );
            }
        }
        +{successful => 1};
    }
    catch {
        my $error = {error => 'Error while rebuilding aggregate tables.'};
        warn 'Exception thrown while rebuilding aggregate tables: ' . $_;
        $error;
    };

    return $output;
}

sub decorate_for_display {
    my $records = shift;

    # We could have custom defined market group that's not in our offerings.
    # Hence, we should be fetch the market group information from the database.
    # market group specification is applied to all databases, we're picking CR here.
    my $db = BOM::Database::ClientDB->new({broker_code => 'CR'})->db;
    my $output = $db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref("SELECT market from bet.limits_market_mapper group by market");
        });
    my $potentially_new_market = $db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref("SELECT market from betonmarkets.quants_wishlist group by market");
        });
    my @market_order = uniq(qw(forex indices commodities volidx default), (map { @$_ } (@$output, @$potentially_new_market)));
    my @type_order = qw(market symbol_default symbol);

    my @sorted_records = ();
    foreach my $market (@market_order) {
        my $group = [grep { $_->{market} and $_->{market} eq $market } @$records];
        my @sorted = ();
        foreach my $type (@type_order) {
            ## This is to enforce a consistent but arbitrary ordering of things via createDisplayTable
            push @sorted, map { $_->[0] }
                sort { $a->[1] cmp $b->[1] }
                map { [$_, (join '.' => sort values %$_)] }
                grep { $_->{type} eq $type } @$group;
        }

        foreach my $record (@sorted) {
            my $type = $record->{type};
            foreach my $key (keys %$record) {
                my $val = $record->{$key};
                if ($val eq 'default') {
                    $record->{$key} = {
                        data_key      => $val,
                        display_value => ((
                                       ($type eq 'symbol_default' and $key eq 'underlying_symbol')
                                    or ($type eq 'market' and $key eq 'market')
                            ) ? $val : '-'
                        ),
                    };
                } else {
                    $record->{$key} = {
                        data_key      => $val,
                        display_value => $val,
                    };
                }
            }
            push @sorted_records, $record;
        }
    }

    my $supported = BOM::Database::QuantsConfig::supported_config_type()->{per_landing_company};

    return {
        records => \@sorted_records,
        header  => [
            [market            => 'Market'],
            [underlying_symbol => 'Underlying'],
            [expiry_type       => 'Expiry Type'],
            [barrier_type      => 'Barrier Type'],
            [contract_group    => 'Contract Group'],
            [landing_company   => 'Landing Company'],
            [comment           => 'Comment'],
            [time_status       => 'Time Status'],       ## Must come before Start Time
            [start_time        => 'Start Time'],
            [end_time          => 'End Time'],
            (map { [$_ => $supported->{$_}] } sort keys %$supported),
        ],
    };
}

sub decorate_for_pending_market_group {
    my $records = shift;

    # group all the underlyings with the same new market group and switch period together
    my %groups;
    foreach my $record (@$records) {
        my $key = join ',', ($record->{market}, $record->{start_time}, $record->{end_time}, $record->{landing_company});
        unless ($groups{$key}) {
            $groups{$key} = $record;
            next;
        }
        $groups{$key}{symbol} .= ",$record->{symbol}";
    }

    # just to adhere to the format in html
    my @records;
    foreach my $data (values %groups) {
        my $record;
        foreach my $key (keys %$data) {
            $record->{$key} = {
                data_key      => $data->{$key},
                display_value => ($data->{$key} eq 'default') ? '-' : $data->{$key},
            };
        }
        push @records, $record;
    }

    return {
        records => \@records,
        header  => [
            [landing_company => 'Landing Company'],
            [market          => 'New Market'],
            [symbol          => 'Underlying Symbol'],
            [start_time      => 'Start Time'],
            [end_time        => 'End Time'],
            [market_switched => 'Switch Status'],
        ],
    };
}

sub update_ultra_short {
    my $args     = shift;
    my $staff    = shift;
    my $duration = $args->{duration};

    unless (defined $duration) {
        return {error => 'Ultra short duration is not specified'};
    }

    $duration = Time::Duration::Concise->new(interval => $duration);
    my $err = try {
        +{error => 'Ultra short span should not be greater than 30 minutes.'} if ($duration->minutes() > 30)
    }
    catch {
        +{error => 'Invalid format.'}
    };
    return $err if $err;

    my $key_name = 'quants.' . $args->{limit_type};
    my $output   = try {
        $app_config->set({$key_name => $duration->seconds()});
        rebuild_aggregate_tables($duration->seconds());
        +{result => $duration->as_string()};
    }
    catch {
        warn $_;
        +{error => 'Failed to set the duration. Please check log.'}
    };

    BOM::Backoffice::QuantsAuditLog::log($staff, "updateultrashortduration", "$key_name new duration[$duration->as_string]");

    return $output;
}

sub save_threshold {
    my $args   = shift;
    my $staff  = shift;
    my $amount = $args->{threshold_amount};

    unless (defined $amount) {
        return {error => 'threshold amount is not specified'};
    }

    if ($amount > 1 or $amount < 0) {
        return {error => 'threshold amount must be between 0 and 1'};
    }

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
    my $key_name = 'quants.' . $args->{limit_type} . '_alert_threshold';
    my $output   = try {
        $app_config->set({$key_name => $amount});
        +{
            id     => $args->{limit_type},
            amount => $amount,
            }

    }
    catch {
        warn $_;
        +{error => 'Failed setting threshold. Please check log.'}
    };

    BOM::Backoffice::QuantsAuditLog::log($staff, "updategloballimitthreshold", "threshold[$key_name] new amount[$amount]");

    return $output;
}

sub update_config_switch {
    my $args  = shift;
    my $staff = shift;

    my $type   = $args->{limit_type};
    my $switch = $args->{limit_status};

    die 'limit_type is undefined' unless ($type);
    die 'invalid switch input' if (not($switch == 0 or $switch == 1));

    my $key_name   = 'quants.' . 'enable_' . $type;
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
    my $output = try {
        $app_config->set({$key_name => $switch});
        return +{status => $switch};
    }
    catch {
        warn $_;
        +{error => 'Failed to update config status. Please check log.'}
    };

    BOM::Backoffice::QuantsAuditLog::log($staff, "updategloballimitconfigswitch", "content: app_config[$key_name] new_status[$switch]");

    return $output;
}

sub get_config_input {
    my $key = shift;

    # exceptions for barrier_type and landing_company
    return ['atm', 'non_atm'] if $key eq 'barrier_type';

    if ($key eq 'landing_company') {
        my $lc = LandingCompany::Registry::get_loaded_landing_companies();
        return [map { $lc->{$_}->{short} } grep { $lc->{$_}->{short} !~ /virtual|vanuatu|champion/i } keys %$lc];
    }

    my $lc       = LandingCompany::Registry::get('virtual');                 # to get everything in the offerings list.
    my $o_config = BOM::Config::Runtime->instance->get_offerings_config();

    if ($key eq 'contract_group' or $key eq 'market') {
        my $db = BOM::Database::ClientDB->new({broker_code => 'CR'})->db;

        if ($key eq 'contract_group') {
            my $output = $db->dbic->run(
                fixup => sub {
                    $_->selectall_arrayref("SELECT * from bet.contract_group");
                });
            my %supported_contract_types =
                map { $_ => 1 }
                map { $_->values_for_key('contract_type') } ($lc->basic_offerings($o_config), $lc->multi_barrier_offerings($o_config));
            return [grep { $supported_contract_types{$_->[0]} } @$output];
        }

        if ($key eq 'market') {
            my $output = $db->dbic->run(
                fixup => sub {
                    $_->selectall_arrayref("SELECT * from bet.limits_market_mapper");
                });
            my %supported_underlying_symbols =
                map { $_ => 1 }
                map { $_->values_for_key('underlying_symbol') } ($lc->basic_offerings($o_config), $lc->multi_barrier_offerings($o_config));
            return [grep { $supported_underlying_symbols{$_->[0]} } @$output];
        }
    }

    my @input = uniq(map { $_->values_for_key($key) } ($lc->basic_offerings($o_config), $lc->multi_barrier_offerings($o_config)));

    if ($key eq 'expiry_type') {
        push @input, 'ultra_short';
    }

    return \@input;
}

sub update_market_group {
    my $args = shift;

    unless ($args->{underlying_symbol} and $args->{market_group} and $args->{market_type}) {
        return {error => 'underlying_symbol, market_group and market_type must be defined.'};
    }

    # remove all whitespace
    $args->{$_} =~ s/\s+//g for (grep { $args->{$_} } qw(underlying_symbol market_group submarket_group market_type));

    if ($args->{market_group} and $args->{market_group} =~ /,/) {
        return {error => 'do not allow more than one market_group.'};
    }

    if ($args->{submarket_group} and $args->{submarket_group} =~ /,/) {
        return {error => 'do not allow more than one submarket_group.'};
    }

    if ($args->{market_type} =~ /,/) {
        return {error => 'do not allow more than one submarket_group.'};
    }

    my $output = try {
        BOM::Database::QuantsConfig->new->update_market_group($args);
        +{success => 1};
    }
    catch {
        my $error = {error => 'Error while updating market group'};
        warn 'Exception thrown while updating market group: ' . $_;
        $error;
    };

    return $output;
}

sub delete_market_group {
    my $args = shift;

    my $groups = try {
        my $qc = BOM::Database::QuantsConfig->new();
        $qc->delete_market_group($args);
        my $market_group = decorate_for_pending_market_group($qc->get_pending_market_group(['default']));
        my $limit        = decorate_for_display($qc->get_all_global_limit(['default']));
        +{
            limit        => $limit,
            market_group => $market_group
        };
    }
    catch {
        +{error => $_};
    };

    return $groups;
}

sub get_global_config_status {
    my $app_config       = BOM::Config::Runtime->instance->app_config;
    my $quants_config    = BOM::Database::QuantsConfig->new();
    my $supported_config = $quants_config->supported_config_type;

    my @config_status;
    foreach my $per_type (qw/per_landing_company per_user/) {
        foreach my $config_name (keys %{$supported_config->{$per_type}}) {
            my $method = 'enable_' . $config_name;
            push @config_status,
                +{
                key          => $config_name,
                display_name => $supported_config->{$per_type}{$config_name},
                status       => $app_config->quants->$method,
                };
        }
    }
    return @config_status;
}

1;
