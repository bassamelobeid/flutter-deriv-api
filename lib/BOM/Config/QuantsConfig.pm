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
use List::Util qw(first all);
use Scalar::Util qw(looks_like_number);
use Finance::Contract::Category;
use Syntax::Keyword::Try;
use YAML::XS qw(LoadFile);
use Finance::Underlying;
use POSIX qw(strftime);

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
    if (defined $landing_company_short and my $config = $default_multiplier_config->{$landing_company_short}) {
        $default_config = $config->{$underlying_symbol};
        $cache_key      = $landing_company_short;
    } else {
        $cache_key      = 'common';
        $default_config = $default_multiplier_config->{$cache_key}{$underlying_symbol};
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
