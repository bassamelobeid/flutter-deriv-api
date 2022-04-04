package BOM::Config::Compliance;

=head1 NAME

BOM::Config::Compliance

=head1 DESCRIPTION

This module implements methods to easily load and save global compliance-related settings

=cut

use strict;
use warnings;
no indirect;

use List::Util qw(uniq);
use JSON::MaybeUTF8 qw(decode_json_utf8);
use BOM::Config::Runtime;

use constant RISK_LEVELS => qw/standard high/;

=head2 new

Class constructor.

Returns an object of type L<BOM::Config::Compliance>.

=cut

sub new {
    my ($class, %args) = @_;

    $args{_countries} = Brands->new()->countries_instance->countries;
    return bless \%args, $class;
}

=head2 _app_config

Returns an instance of global app-config class, used for reading data.

=cut

sub _app_config {
    return BOM::Config::Runtime->instance->app_config;
}

=head2 _countries

Returns contry settings as an object.

=cut

sub _countries {
    my $self = shift;

    return $self->{_countries};
}

=head2 get_jurisdiction_risk_rating

Gets list of countries categorized by their landing company name, along with the app-config revision number. 

Returns a hashref with the following structure:

{ revision => ..., standard => [...], hight => [...] } 

=cut

sub get_jurisdiction_risk_rating {
    my ($self) = @_;

    my $app_config = $self->_app_config;
    my $result     = decode_json_utf8($app_config->get('compliance.jurisdiction_risk_rating'));
    $result->{revision} = $app_config->global_revision;

    $result->{$_} //= [] for RISK_LEVELS;
    $result->{$_} = [sort $result->{$_}->@*] for RISK_LEVELS;

    return $result;
}

=head2 validate_jurisdiction_risk_rating

Saves the country lists assigned to jurisdiction risk levels. It also validates the input and reutrns an error message on failure.
It accepts the following named args:

=over 4

=item * standard - list of countries with standard risk level.

=item * high - list of countries with high risk level.

=item * revision - app-config revision with which the data was retrieved.

=back

It returns the same structure as a hash-ref with sorted, unique country lists.

=cut

sub validate_jurisdiction_risk_rating {
    my ($self, %args) = @_;

    die "App config revision is missing\n" unless $args{revision};

    my $result = {revision => $args{revision}};

    # an auxilary hash for finding duplicate country codes
    my %contry_to_risk_level;

    for my $risk_level (RISK_LEVELS) {
        my @country_list = uniq $args{$risk_level}->@*;

        for my $country (@country_list) {
            next unless $country;
            if ($contry_to_risk_level{$country}) {
                die "Duplicate country found: <$country> appears both in $contry_to_risk_level{$country} and $risk_level risk listings\n";
            } else {
                $contry_to_risk_level{$country} = $risk_level;
            }

            die "Invalid country code <$country> in $risk_level risk listing\n" unless $self->_countries->country_from_code($country);
        }
        $result->{$risk_level} = [sort @country_list];
    }

    return $result;
}

1;
