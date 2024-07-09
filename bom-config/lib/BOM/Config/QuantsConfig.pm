package BOM::Config::QuantsConfig;

=head1 NAME

C<BOM::Config::QuantsConfig>

=head1 DESCRIPTION

A class to handle dynamic quants config.

=head1 SYNOPSIS

    use BOM::Config::QuantsConfig;
    use Date::Utility;
    use BOM::Config::Chronicle;

    my $qc = BOM::Config::QuantsConfig->new(
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader,
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer,
        recorded_date    => Date::Utility->new
    );

    $qc->save('test', +{test => 1});

=cut

use Moose;

use Date::Utility;
use LandingCompany::Registry;
use List::Util   qw(first all);
use Scalar::Util qw(looks_like_number);
use BOM::Config::Redis;
use BOM::Config;
use Finance::Contract::Category;
use Syntax::Keyword::Try;
use YAML::XS qw(LoadFile);
use Finance::Underlying;
use POSIX         qw(strftime);
use JSON::MaybeXS qw(encode_json decode_json);

use BOM::Config::Runtime;

use constant {
    CONFIG_NAMESPACE  => 'quants_config',
    MULTIPLIER_CONFIG => 'multiplier_config',
};

my $default_multiplier_config     = LoadFile('/home/git/regentmarkets/bom-config/share/default_multiplier_config.yml');
my $dividend_scheduler_yml        = LoadFile('/home/git/regentmarkets/bom-config/share/dividend_scheduler.yml');
my $mt5_symbols_mapping           = LoadFile('/home/git/regentmarkets/bom-config/share/mt5-symbols.yml');
my $default_barrier_multipler_yml = LoadFile('/home/git/regentmarkets/bom-config/share/default_barrier_multiplier.yml');

has [qw(chronicle_reader chronicle_writer)] => (is => 'ro');

has [qw(recorded_date for_date)] => (
    is      => 'ro',
    default => undef,
);

=head2 contract_category

Contract category which we need the respected config for

=cut

has contract_category => (
    is => 'rw',
);

=head2 redis_write

redis write instance

=cut

has redis_write => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_redis_write',
);

=head2 _build_redis_write

Building a redis write instance

=cut

sub _build_redis_write {

    return BOM::Config::Redis::redis_replicated_write();
}

=head2 redis_read

redis read instance

=cut

has redis_read => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_redis_read',
);

=head2 _build_redis_read

Building a redis read instance

=cut

sub _build_redis_read {

    return BOM::Config::Redis::redis_replicated_read();
}

=head2 save_config

save config into quants_config namespace.

Example:

    $obj->save_config('commission', {contract_type => 'CALL,PUT', commission => 0.2});

=cut

sub save_config {
    my ($self, $config_type, $args) = @_;

    my $config;
    if ($config_type eq 'custom_multiplier_commission') {
        $config = $args;
    } elsif ($config_type =~ /commission/) {
        $config = $self->_process_commission_config($args);
    } elsif ($config_type =~ /multiplier_config/) {
        $config = $self->_process_multiplier_config($config_type, $args);
    } elsif ($config_type =~ /callputspread_barrier_multiplier/) {
        $config = $args;
    } elsif ($config_type =~ /deal_cancellation/) {
        $config = $args;
    } elsif ($config_type =~ /turbos/) {
        $config = $args;
    } elsif ($config_type =~ /accumulator/) {
        $config = $self->_process_accumulator_config($config_type, $args);
    } else {
        die "unregconized config type [$config_type]";
    }
    $self->chronicle_writer->set(CONFIG_NAMESPACE, $config_type, $config, $self->recorded_date);

    return $config->{$args->{name}} if $args->{name};
    return $config;
}

sub _process_commission_config {
    my ($self, $args) = @_;

    my %args            = %$args;
    my $existing_config = $self->chronicle_reader->get(CONFIG_NAMESPACE, 'commission') // {};

    my $identifier = $args{name} || die 'name is required';
    die 'name should only contain words and integers' unless $identifier =~ /^([A-Za-z0-9]+ ?)*$/;
    die 'Cannot use an identical name.' if $existing_config->{$identifier};
    die 'start_time is required' unless $args{start_time};
    die 'end_time is required'   unless $args{end_time};

    for my $time_name (qw(start_time end_time)) {
        $args{$time_name} =~ s/^\s+|\s+$//g;
        try {
            $args{$time_name} = Date::Utility->new($args{$time_name})->epoch;
        } catch {
            die "Invalid $time_name format";
        }
    }

    die "start time must be before end time" if $args{start_time} >= $args{end_time};

    foreach my $key (keys %args) {
        next if $key eq 'name';

        if ($args{$key} eq '') {
            delete $args{$key};
            next;
        }

        if ($key eq 'contract_type' or $key eq 'currency_symbol' or $key eq 'underlying_symbol') {
            my @values = map { my $v = $_; $v =~ s/\s+//g; $v } split ',', $args{$key};
            if ($key ne 'currency_symbol') {
                _validate($key, $_) or die "invalid input for $key [$_]" foreach @values;
            } else {
                @values = map { uc } @values;
            }
            $args{$key} = \@values;
        } elsif ($key =~ /(ITM|OTM)/) {
            die "invalid input for $key" unless looks_like_number($args{$key});
        }
    }

    $existing_config->{$identifier} = \%args;
    $self->_cleanup($existing_config);

    return $existing_config;
}

sub _process_multiplier_config {
    my ($self, $config_type, $args) = @_;

    my $multiplier_range = $args->{multiplier_range};
    my $stop_out_level   = $args->{stop_out_level};

    # special regulatory requirement for malta invest to have a maximum commission of 0.1%
    if ($config_type =~ /maltainvest/ and $args->{commission} > 0.001) {
        die 'Commission for Malta Invest cannot be more than 0.1%';
    }

    die 'multiplier range and stop out level definition does not match'
        unless (scalar(@$multiplier_range) == scalar(keys %$stop_out_level) && all { defined $stop_out_level->{$_} } @$multiplier_range);

    die 'stop out level is out of range. Allowable range from 0 to 70'
        if grep { $stop_out_level->{$_} < 0 || $stop_out_level->{$_} > 70 } keys %$stop_out_level;

    if (my $expiry = $args->{expiry}) {
        my ($day) = $expiry =~ /^(\d+)d$/;
        die 'only \'d\'  unit and integer number of days are allowed' unless defined $day;
        die 'expiry has to be greater than 1d' if $day < 1;
    }

    return $args;
}

sub _cleanup {
    my ($self, $existing_configs) = @_;

    foreach my $name (keys %$existing_configs) {
        delete $existing_configs->{$name} if ($existing_configs->{$name}->{end_time} < $self->recorded_date->epoch);
    }

    return;
}

=head2 get_config

Retrieves config based on contract_type and underlying_symbol matching

Example:

    $obj->get_config('commision', {underlying_symbol => 'frxUSDJPY'});

=cut

sub get_config {
    my ($self, $config_type, $args) = @_;

    my $method          = $self->for_date ? 'get_for' : 'get';
    my $existing_config = $self->chronicle_reader->$method(CONFIG_NAMESPACE, $config_type, $self->for_date) // {};

    # custom commission requires some special treatment.
    return $self->_process_commission($existing_config, $args) if $config_type eq 'commission' or $config_type eq 'custom_multiplier_commission';
    return $existing_config;
}

=head2 get_multiplier_config

Get config for multiplier options for a specific landing company and underlying symbol.

Example:

    $obj->get_multiplier_config('maltainvest', 'frxUSDJPY');

Returns a hash reference.

=cut

sub get_multiplier_config {
    my ($self, $landing_company_short, $underlying_symbol) = @_;

    my ($default_config, $cache_key);

    # landing company can be undefined if user is not logged in
    if (defined $landing_company_short and my $config = get_multiplier_config_default()->{$landing_company_short}) {
        $default_config = $config->{$underlying_symbol};
        $cache_key      = $landing_company_short;
    } else {
        $cache_key      = 'common';
        $default_config = get_multiplier_config_default()->{$cache_key}{$underlying_symbol};
    }

    my $redis_key       = join('::', MULTIPLIER_CONFIG, $cache_key, $underlying_symbol);
    my $method          = $self->for_date ? 'get_for' : 'get';
    my $existing_config = $self->chronicle_reader->$method(CONFIG_NAMESPACE, $redis_key, $self->for_date);

    return {}                 unless $default_config;
    return {%$default_config} unless $existing_config;

    # sometimes we add something new to the yaml file without updating the cache.
    return {%$default_config, %$existing_config};
}

=head2 get_multiplier_config_default

Returns the C<$default_multiplier_config> defined in yaml.

=cut

sub get_multiplier_config_default {
    return $default_multiplier_config;
}

=head2 _process_accumulator_config

Before saving any accumulator config to both Redis and DB, some modifications might be needed. 
In this functions based on the type of the conifg these measures are addressed.  

=cut

sub _process_accumulator_config {
    my ($self, $redis_key, $args) = @_;

    my @redis_key_split = split("::", $redis_key);
    my $config_category = $redis_key_split[1];

    # for 'per_symbol' config, other than storing it into Chronicle, the last recent 10 config changes are also stored into a
    # sorted set inside Redis.
    if ($config_category eq 'per_symbol') {
        # this field is added to make sure we always have unique values so that existing sorted set members are not updated.
        $args->{u_id} = rand();
        my $config            = encode_json($args);
        my $landing_company   = $redis_key_split[2];
        my $underlying_symbol = $redis_key_split[3];
        my $cached_redis_key =
            join('::', CONFIG_NAMESPACE, $self->contract_category, 'cached_per_symbol_conifg', $landing_company, $underlying_symbol);

        my $sorted_set_len = $self->redis_read->execute('zcard', $cached_redis_key);

        if ($sorted_set_len and $sorted_set_len >= 10) {
            $self->redis_write->execute('zpopmin', $cached_redis_key);
            $self->redis_write->execute('zadd', $cached_redis_key, 'NX', $self->recorded_date->epoch, $config);
        } else {
            $self->redis_write->execute('zadd', $cached_redis_key, 'NX', $self->recorded_date->epoch, $config);
        }
    }

    return $args;

}

=head2 get_per_symbol_config

This method returns the config per landing company per symbol. 
When the $need_latest_cache tag is true, it will return the latest cache inside Chronicle Redis cache to be used in creating new contracts and also for BackOffice.
Otherwise it will check for the conifg first inside a sorted set in Redis which contains the last few configs. This set is used 
to avoid calling DB for past conifgs which are used by yet open contracts. 
If we didn't have the requiered cache for the specific time iniside the sorted set in Redis, it will be fetched from DB, but since it
is for epxired contracts, it won't overload DB. 

=cut

sub get_per_symbol_config {
    my ($self, $args) = @_;

    return unless my $underlying_symbol = $args->{underlying_symbol};
    my $landing_company = $args->{landing_company} ? $args->{landing_company} : 'common';

    my $redis_key        = join('::', $self->contract_category, 'per_symbol', $landing_company, $underlying_symbol);
    my $cached_redis_key = join('::', CONFIG_NAMESPACE, $self->contract_category, 'cached_per_symbol_conifg', $landing_company, $underlying_symbol);

    if (my $last_cache = $self->chronicle_reader->get(CONFIG_NAMESPACE, $redis_key)) {

        if ($args->{need_latest_cache}) {
            # There could be new keys in the default config that are not present in the last_cache.
            my $defauly_config = $self->get_default_config('per_symbol')->{$landing_company}->{$underlying_symbol};
            $last_cache = update_with_missing_keys($last_cache, $defauly_config);
            return $last_cache;
        }

        #look into a Redis sorted set to see if the required config is cached inside it.
        my $cached_configs = $self->redis_read->execute('zrange', $cached_redis_key, '0', $self->for_date->epoch, 'byscore');
        return decode_json(pop(@$cached_configs)) if $cached_configs and @$cached_configs;

        # in case of no Redis cache, we look for the config inside DB for the specific date.
        my $config = $self->chronicle_reader->get_for(CONFIG_NAMESPACE, $redis_key, $self->for_date);
        return $config if $config;

        # this case is needed when we need a config before the first insertion into Chronicle.
        return $self->get_default_config('per_symbol')->{$landing_company}->{$underlying_symbol};

    } else {
        return $self->get_default_config('per_symbol')->{$landing_company}->{$underlying_symbol};
    }
    return;

}

=head2 update_with_missing_keys

Updates a given 'last_cache' hash reference with missing keys from a 'default_config' hash reference.

This function ensures that all keys present in 'default_config' but missing in 'last_cache' are added.
For nested hash structures, it checks and adds missing sub-keys at one level deep only. It does not replace existing values, unless they are missing.

=over 4

=item Parameters:

=item C<$last_cache>: (HashRef) The last_cache hash reference that may be missing some keys.

=item C<$default_config>: (HashRef) The hash reference containing default keys and values that should be present in C<$last_cache>.

=back

=over 4

=item Returns:

=item C<$last_cache>: (HashRef) The updated hash reference with missing keys added from C<$default_config>.

=back

=cut

sub update_with_missing_keys {
    my ($last_cache, $default_config) = @_;

    foreach my $key (keys %$default_config) {
        # Only add the key from default_config if it doesn't exist in last_cache
        if (!exists $last_cache->{$key}) {
            $last_cache->{$key} = $default_config->{$key};
        }
        # If it's a hash and the key exists in both, and still want to ensure nested keys are updated
        elsif (ref $last_cache->{$key} eq 'HASH' && ref $default_config->{$key} eq 'HASH') {
            foreach my $sub_key (keys %{$default_config->{$key}}) {
                if (!exists $last_cache->{$key}{$sub_key}) {
                    $last_cache->{$key}{$sub_key} = $default_config->{$key}{$sub_key};
                }
            }
        }
    }

    return $last_cache;
}

=head2 get_default_config

This function would return the default config for a specific contract category and for the following config types:
- per_symbol
- per_symbol_limits
- risk_profile

=cut

sub get_default_config {
    my ($self, $config_type) = @_;

    #defualt risk profile value is the same for all contract types, but other configs can be different for each type
    return LoadFile("/home/git/regentmarkets/bom-config/share/default_" . $config_type . "_config.yml") if $config_type eq 'risk_profile';
    return LoadFile("/home/git/regentmarkets/bom-config/share/default_" . $self->contract_category . "_" . $config_type . "_config.yml");
}

=head2 get_per_symbol_limits

Returns the limits imposed on each symbol for a specific contract category. 
These limits are part of the Risk Management tool. 

=cut

sub get_per_symbol_limits {
    my ($self, $args) = @_;

    return unless my $underlying_symbol = $args->{underlying_symbol};
    my $landing_company = $args->{landing_company} ? $args->{landing_company} : 'common';

    my $redis_key       = join("::", $self->contract_category, 'per_symbol_limits',, $landing_company, $underlying_symbol);
    my $existing_config = $self->chronicle_reader->get(CONFIG_NAMESPACE, $redis_key);

    return $existing_config ? $existing_config : $self->get_default_config('per_symbol_limits')->{$landing_company}->{$underlying_symbol};
}

=head2 get_user_specific_limits

Returns the limits imposed on clients for a specific contract category. 
These limits are part of the Risk Management tool. 

=cut

sub get_user_specific_limits {
    my $self = shift;

    my $redis_key       = join("::", $self->contract_category, 'user_specific_limits');
    my $existing_config = $self->chronicle_reader->get(CONFIG_NAMESPACE, $redis_key);

    return $existing_config ? $existing_config : undef;
}

=head2 get_max_stake_per_risk_profile

Returns a hashref containing the values for each risk profile's max stake value. 

=cut

sub get_max_stake_per_risk_profile {
    my ($self, $risk_profile) = @_;

    my $redis_key       = join("::", $self->contract_category, 'max_stake_per_risk_profile', $risk_profile);
    my $existing_config = $self->chronicle_reader->get(CONFIG_NAMESPACE, $redis_key);

    return $existing_config ? $existing_config : $self->get_default_config('risk_profile')->{$risk_profile};
}

=head2 get_risk_profile_per_symbol

Returns the risk level imposed on each symbol for specific contract categories. 

=cut

sub get_risk_profile_per_symbol {
    my $self = shift;

    my $redis_key       = join("::", $self->contract_category, 'risk_profile_per_symbol');
    my $existing_config = $self->chronicle_reader->get(CONFIG_NAMESPACE, $redis_key);

    return $existing_config ? $existing_config : undef;
}

=head2 get_risk_profile_per_market

Returns the risk level imposed on each market for specific contract categories. 

=cut

sub get_risk_profile_per_market {
    my $self = shift;

    my $redis_key       = join("::", $self->contract_category, 'risk_profile_per_market');
    my $existing_config = $self->chronicle_reader->get(CONFIG_NAMESPACE, $redis_key);

    return $existing_config ? $existing_config : undef;
}

=head2 _process_commission

process commission

=cut

sub _process_commission {
    my ($self, $existing_config, $args) = @_;

    return [values %$existing_config] unless $args;

    my $finance_underlying;
    my $underlying_symbol = $args->{underlying_symbol};
    $finance_underlying = eval { Finance::Underlying->by_symbol($underlying_symbol) } if $underlying_symbol and $underlying_symbol =~ /^(frx|WLD)/;

    my $foreign_curr  = '';
    my $domestic_curr = '';

    if ($finance_underlying) {
        if ($underlying_symbol =~ /^frx/) {
            $foreign_curr  = $finance_underlying->asset;
            $domestic_curr = $finance_underlying->quoted_currency;
        } elsif ($underlying_symbol =~ /^WLD/) {
            $foreign_curr  = 'WLD';
            $domestic_curr = $finance_underlying->asset;
        }
    }

    my @match;
    foreach my $key (keys %$existing_config) {
        my $config          = $existing_config->{$key};
        my %underlying_hash = map { $_ => 1 } @{$config->{underlying_symbol} // []};

        if (!$config->{bias}) {
            push @match, $config
                if ($underlying_hash{$underlying_symbol}
                || ($config->{currency_symbol} && first { $underlying_symbol =~ /$_/ } @{$config->{currency_symbol}}));
        } else {
            my %currency_hash = map { $_ => 1 } @{$config->{currency_symbol} // []};
            if ($underlying_hash{$underlying_symbol} || $currency_hash{$foreign_curr}) {
                push @match, $config if ($config->{bias} eq 'long'  && $args->{contract_type} =~ /CALL/);
                push @match, $config if ($config->{bias} eq 'short' && $args->{contract_type} =~ /PUT/);
            } elsif ($currency_hash{$domestic_curr}) {
                push @match, $config if ($config->{bias} eq 'long'  && $args->{contract_type} =~ /PUT/);
                push @match, $config if ($config->{bias} eq 'short' && $args->{contract_type} =~ /CALL/);
            }
        }
    }

    return \@match;
}

=head2 delete_config

Deletes config base on config_type and name.

Example:

    $obj->delete_config('commission', 'test 1');

=cut

sub delete_config {
    my ($self, $config_type, $name) = @_;

    my $existing_config = $self->chronicle_reader->get(CONFIG_NAMESPACE, $config_type) // {};

    die 'config does not exist config_type [' . $config_type . '] name [' . $name . ']' unless $existing_config->{$name};

    my $deleted = delete $existing_config->{$name};
    $self->chronicle_writer->set(CONFIG_NAMESPACE, $config_type, $existing_config, Date::Utility->new);

    return $deleted;
}

sub _validate {
    my ($key, $value) = @_;

    my @valid;
    if ($key eq 'contract_type') {
        @valid = keys %{Finance::Contract::Category::get_all_contract_types()};
    } else {
        my $offerings_obj = LandingCompany::Registry->get_default_company->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config);
        @valid = $offerings_obj->values_for_key($key);
    }

    my %valid_inputs = map { $_ => 1 } @valid;

    return 0 unless $valid_inputs{$value};
    return 1;
}

=head2 custom_deal_cancellation

C</custom_deal_cancellation> will return the custom deal cancellation set on backoffice.

Example:

    $obj->custom_deal_cancellation(underlying_symbol, landing_company_short, date_pricing);

=cut

sub custom_deal_cancellation {
    my ($self, $underlying_symbol, $landing_company_short, $date_pricing) = @_;

    my $custom_deal_cancellation_configs = $self->chronicle_reader->get(CONFIG_NAMESPACE, "deal_cancellation", $self->for_date) // {};
    my $dc_config_id                     = join('_', $underlying_symbol, $landing_company_short);

    if (!$custom_deal_cancellation_configs->{$dc_config_id}) {
        return 0;
    }

    my $start_datetime_limit = $custom_deal_cancellation_configs->{$dc_config_id}{"start_datetime_limit"};
    my $end_datetime_limit   = $custom_deal_cancellation_configs->{$dc_config_id}{"end_datetime_limit"};

    # In case the limitation was specified in time range and not date,
    # we'll add the current date to avoid errors of the Date::Utility instaniation.
    if ($start_datetime_limit =~ /^\d{2}:\d{2}:\d{2}$/ && $end_datetime_limit =~ /^\d{2}:\d{2}:\d{2}$/) {
        $start_datetime_limit = strftime('%Y-%m-%d', gmtime) . " " . $start_datetime_limit;
        $end_datetime_limit   = strftime('%Y-%m-%d', gmtime) . " " . $end_datetime_limit;
    }

    my $start_dt = Date::Utility->new($start_datetime_limit);
    my $end_dt   = Date::Utility->new($end_datetime_limit);

    if ($date_pricing >= $start_dt->epoch and $date_pricing < $end_dt->epoch) {
        my @dc_type = split(',', $custom_deal_cancellation_configs->{$dc_config_id}{"dc_types"});
        return \@dc_type;
    }

    return 0;
}

=head2 get_mt5_symbols_mapping

C</get_mt5_symbols_mapping> will return the mapped mt5 symbol with deriv symbol.

Example:

    $obj->get_mt5_symbols_mapping;

=cut

sub get_mt5_symbols_mapping {
    return $mt5_symbols_mapping;
}

=head2 get_dividend_scheduler_yml

C</get_dividend_scheduler_yml> will return the symbols that will be used for dividend scheduler.

Example:

    $obj->get_dividend_scheduler_yml;

=cut

sub get_dividend_scheduler_yml {
    return $dividend_scheduler_yml;
}

=head2 default_barrier_multipler_yml

C</default_barrier_multipler_yml> will return the default barrier multiplier that will be used for barrier calculation.

Example:

    $obj->default_barrier_multipler_yml;

=cut

sub default_barrier_multipler_yml {
    return $default_barrier_multipler_yml;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
