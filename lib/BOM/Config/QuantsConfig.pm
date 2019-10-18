package BOM::Config::QuantsConfig;

use Moose;

=head1 NAME

BOM::Config::QuantsConfig - A class to handle dynamic quants config

=head1 USAGE

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

use Date::Utility;
use LandingCompany::Registry;
use List::Util qw(first);
use Scalar::Util qw(looks_like_number);
use Finance::Contract::Category;
use Try::Tiny;
use YAML::XS qw(LoadFile);

use BOM::Config::Runtime;

my $default_multiplier_config = LoadFile('/home/git/regentmarkets/bom-config/share/default_multiplier_config.yml');

has [qw(chronicle_reader chronicle_writer)] => (is => 'ro');

has [qw(recorded_date for_date)] => (
    is      => 'ro',
    default => undef,
);

my $namespace = 'quants_config';

=head2 save_config

save config into quants_config namespace.

->save_config('commission', {contract_type => 'CALL,PUT', commission => 0.2})

=cut

sub save_config {
    my ($self, $config_type, $args) = @_;

    my $method = '_' . $config_type;
    my $config = $self->$method($args);

    $self->chronicle_writer->set($namespace, $config_type, $config, $self->recorded_date);

    return $config->{$args->{name}};
}

sub _commission {
    my ($self, $args) = @_;

    my %args = %$args;
    my $existing_config = $self->chronicle_reader->get($namespace, 'commission') // {};

    my $identifier = $args{name} || die 'name is required';
    die 'name should only contain words and integers' unless $identifier =~ /^([A-Za-z0-9]+ ?)*$/;
    die 'Cannot use an identical name.' if $existing_config->{$identifier};
    die 'start_time is required' unless $args{start_time};
    die 'end_time is required'   unless $args{end_time};

    for (qw(start_time end_time)) {
        $args{$_} =~ s/^\s+|\s+$//g;
        $args{$_} = try {
            Date::Utility->new($args{$_})->epoch;
        }
        catch {
            die "Invalid $_ format";
        };
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

sub _cleanup {
    my ($self, $existing_configs) = @_;

    foreach my $name (keys %$existing_configs) {
        delete $existing_configs->{$name} if ($existing_configs->{$name}->{end_time} < $self->recorded_date->epoch);
    }

    return;
}

=head2 get_config

Retrieves config based on contract_type and underlying_symbol matching

->get_config('commision', {underlying_symbol => 'frxUSDJPY'})

=cut

sub get_config {
    my ($self, $config_type, $args) = @_;

    my $method = $self->for_date ? 'get_for' : 'get';
    my $existing_config = $self->chronicle_reader->$method($namespace, $config_type, $self->for_date) // {};

    # custom commission requires some special treatment.
    return $self->_process_commission($existing_config, $args) if $config_type eq 'commission';
    return $self->_process_multiplier_config($existing_config, $args) if $config_type eq 'multiplier_config';
    return $existing_config;
}

sub _process_multiplier_config {
    my ($self, $existing_config, $args) = @_;

    # if there's no existing config in chronicle, loads it from default yaml file.
    my $config = %$existing_config ? $existing_config : $default_multiplier_config;

    return $config unless $args->{underlying_symbol};
    return $config->{$args->{underlying_symbol}};
}

sub _process_commission {
    my ($self, $existing_config, $args) = @_;

    return [values %$existing_config] unless $args;

    my ($foreign_curr, $domestic_curr) = $args->{underlying_symbol} =~ /^(?:frx|(?=WLD))(\w{3})(\w{3})$/;

    my @match;
    foreach my $key (keys %$existing_config) {
        my $config = $existing_config->{$key};
        my %underlying_hash = map { $_ => 1 } @{$config->{underlying_symbol} // []};

        if (!$config->{bias}) {
            push @match, $config
                if ($underlying_hash{$args->{underlying_symbol}}
                || ($config->{currency_symbol} && first { $args->{underlying_symbol} =~ /$_/ } @{$config->{currency_symbol}}));
        } else {
            my %currency_hash = map { $_ => 1 } @{$config->{currency_symbol} // []};
            if ($underlying_hash{$args->{underlying_symbol}} || $currency_hash{$foreign_curr}) {
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

Deletes config base on config_type and name

->delete_config('commission', 'test 1')

=cut

sub delete_config {
    my ($self, $config_type, $name) = @_;

    my $existing_config = $self->chronicle_reader->get($namespace, $config_type) // {};

    die 'config does not exist config_type [' . $config_type . '] name [' . $name . ']' unless $existing_config->{$name};

    my $deleted = delete $existing_config->{$name};
    $self->chronicle_writer->set($namespace, $config_type, $existing_config, Date::Utility->new);

    return $deleted;
}

sub _validate {
    my ($key, $value) = @_;

    my @valid;
    if ($key eq 'contract_type') {
        @valid = keys %{Finance::Contract::Category::get_all_contract_types()};
    } else {
        my $offerings_obj = LandingCompany::Registry::get('svg')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config);
        @valid = $offerings_obj->values_for_key($key);
    }

    my %valid_inputs = map { $_ => 1 } @valid;

    return 0 unless $valid_inputs{$value};
    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
