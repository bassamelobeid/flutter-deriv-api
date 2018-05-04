package BOM::Backoffice::QuantsConfigHelper;

use strict;
use warnings;

use BOM::Database::QuantsConfig;
use BOM::Database::ClientDB;
use BOM::Platform::Runtime;

use LandingCompany::Registry;
use Finance::Contract::Category;
use Try::Tiny;
use YAML::XS qw(LoadFile);
use List::Util qw(uniq);

sub save_limit {
    my $args = shift;

    $args->{$_} =~ s/\s+//g for keys %$args;

    # clean up and restructure inputs
    my %new_args = map {
              ($_ =~ /limit_type|limit_amount/) ? ($_ => $args->{$_})
            : ($_ =~ /underlying_symbol/) ? ($_ => [split ',', $args->{$_}])
            : ($_ => [$args->{$_} =~ /$_=(\w+)/g])
        } grep {
        $args->{$_}
        } keys %$args;

    my $limits = try {
        my $qc = BOM::Database::QuantsConfig->new();
        $qc->set_global_limit(\%new_args);
        my $decorated_data = decorate_for_display($qc->get_all_global_limit(['default']));
        +{data => $decorated_data};

    }
    catch {
        +{error => $_};
    };

    return $limits;
}

sub delete_limit {
    my $args = shift;

    my $limits = try {
        my $qc = BOM::Database::QuantsConfig->new();
        $qc->delete_global_limit($args);
        my $decorated_data = decorate_for_display($qc->get_all_global_limit(['default']));
        +{data => $decorated_data};
    }
    catch {
        +{error => $_};
    };

    return $limits;
}

sub update_contract_group {
    my $args = shift;

    $args->{contract_type} =~ s/\s+//g;
    my $contract_types = $args->{contract_type};
    my $contract_group = $args->{contract_group};

    my $output = try {
        my $dbs = BOM::Database::QuantsConfig->new->_db_list('default');
        foreach my $db (@$dbs) {
            my $dbic = $db->dbic;
            foreach my $contract_type (split ',', $contract_types) {
                if ($contract_group eq 'default') {
                    $contract_group = Finance::Contract::Category::get_all_contract_types()->{$contract_type}{category};
                }
                $dbic->run(
                    fixup => sub {
                        $_->do(qq{SELECT bet.update_contract_group(?,?)}, undef, $contract_type, $contract_group);
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

    my $output = try {
        foreach my $method (qw(rebuild_open_contract_aggregates rebuild_global_aggregates)) {
            my $dbs = BOM::Database::QuantsConfig->new->_db_list('default');
            foreach my $db (@$dbs) {
                my $dbic = $db->dbic;
                $dbic->run(
                    fixup => sub {
                        $_->do(qq{SELECT bet.$method()});
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

    my @market_order = qw(forex indices commodities stocks volidx default);
    my @type_order   = qw(market symbol_default symbol);

    my @sorted_records = ();
    foreach my $market (@market_order) {
        my $group = [grep { $_->{market} and $_->{market} eq $market } @$records];
        my @sorted = ();
        foreach my $type (@type_order) {
            push @sorted, grep { $_->{type} eq $type } @$group;
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
            (map { [$_ => $supported->{$_}] } keys %$supported),
        ],
    };
}

sub save_threshold {
    my $args = shift;

    my $amount = $args->{threshold_amount};

    unless (defined $amount) {
        return {error => 'threshold amount is not specified'};
    }

    if ($amount > 1 or $amount < 0) {
        return {error => 'threshold amount must be between 0 and 1'};
    }

    my $app_config     = BOM::Platform::Runtime->instance->app_config;
    my $threshold_name = $args->{limit_type} . '_alert_threshold';
    my $output         = try {
        $app_config->quants->$threshold_name($amount);
        $app_config->save_dynamic();
        +{
            id     => $args->{limit_type},
            amount => $amount,
            }

    }
    catch {
        warn $_;
        +{error => 'Failed setting threshold. Please check log.'}
    };

    return $output;
}

sub update_config_switch {
    my $args = shift;

    my $type   = $args->{limit_type};
    my $switch = $args->{limit_status};

    die 'limit_type is undefined' unless ($type);
    die 'invalid switch input' if (not($switch == 0 or $switch == 1));

    my $method     = 'enable_' . $type;
    my $app_config = BOM::Platform::Runtime->instance->app_config;
    $app_config->check_for_update();
    my $output = try {
        my $data_in_redis = $app_config->chronicle_reader->get($app_config->setting_namespace, $app_config->setting_name);
        # due to app_config data_set cache, config might not be saved.
        return {error => 'Config not saved. Please refresh the page and try again'} if $data_in_redis->{_rev} ne $app_config->data_set->{version};
        $app_config->quants->$method($switch);
        $app_config->save_dynamic();
        return +{status => $switch};
    }
    catch {
        warn $_;
        +{error => 'Failed to update config status. Please check log.'}
    };

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

    if ($key eq 'contract_group') {
        my $db = BOM::Database::ClientDB->new({broker_code => 'CR'})->db;
        return $db->dbic->run(
            fixup => sub {
                $_->selectall_arrayref('SELECT * from bet.contract_group');
            });
    }

    my $lc       = LandingCompany::Registry::get('virtual');                   # to get everything in the offerings list.
    my $o_config = BOM::Platform::Runtime->instance->get_offerings_config();

    return [uniq(map { $_->values_for_key($key) } ($lc->basic_offerings($o_config), $lc->multi_barrier_offerings($o_config)))];
}

1;
