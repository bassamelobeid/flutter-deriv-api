package BOM::Platform::QuantsConfig;

use Moose;

=head1 NAME

BOM::Platform::QuantsConfig - A class to handle dynamic quants config

=cut

use Date::Utility;
use LandingCompany::Offerings qw(get_offerings_flyby);
use Scalar::Util qw(looks_like_number);
use List::Util qw(first);

has [qw(chronicle_reader chronicle_writer)] => (is => 'ro');

has for_date => (
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

    my %args = %$args;
    my $existing_config = $self->chronicle_reader->get($namespace, $config_type) // {};

    my $identifier = $args{name} // die 'name is required';
    foreach my $key (keys %args) {
        next if $key eq 'name';

        if ($args{$key} eq '') {
            delete $args{$key};
            next;
        }

        if ($key eq 'contract_type' or $key eq 'currency_symbol' or $key eq 'underlying_symbol') {
            my @values = split ',', $args{$key};
            if ($key ne 'currency_symbol') {
                _validate($key, $_) or die "invalid input for $key [$_]" foreach @values;
            }
            $args{$key} = \@values;
        } elsif (!looks_like_number($args{$key})) {
            die "invalid input for $key [" . $args{$key} . ']';
        }
    }

    $existing_config->{$identifier} = \%args;

    $self->chronicle_writer->set($namespace, $config_type, $existing_config, Date::Utility->new);

    return \%args;
}

=head2 get_config

Retrieves config based on contract_type and underlying_symbol matching

->get_config('commision', {underlying_symbol => 'frxUSDJPY'})

=cut

sub get_config {
    my ($self, $config_type, $args) = @_;

    my $method = $self->for_date ? 'get_for' : 'get';
    my $existing_config = $self->chronicle_reader->$method($namespace, $config_type, $self->for_date) // {};
    return [values %$existing_config] unless $args;

    my @match;
    foreach my $key (keys %$existing_config) {
        my $config         = $existing_config->{$key};
        my $matched_ct     = (!$config->{contract_type} || first { $_ eq $args->{contract_type} } @{$config->{contract_type}});
        my $matched_all_ul = (!$config->{underlying_symbol} && !$config->{currency_symbol});
        my $matched_ul     = ($config->{underlying_symbol} && first { $_ eq $args->{underlying_symbol} } @{$config->{underlying_symbol}});
        my $matched_curr   = ($config->{currency_symbol} && first { $args->{underlying_symbol} =~ /$_/ } @{$config->{currency_symbol}});
        if ($matched_ct && ($matched_all_ul || $matched_ul || $matched_curr)) {
            push @match, $config;
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

    my $fb = get_offerings_flyby();
    my %valid_inputs = map { $_ => 1 } $fb->values_for_key($key);

    return 0 unless $valid_inputs{$value};
    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
