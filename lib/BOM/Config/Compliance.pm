package BOM::Config::Compliance;

=head1 NAME

BOM::Config::Compliance

=head1 DESCRIPTION

This module implements methods to easily load and save global compliance-related settings

=cut

use strict;
use warnings;
no indirect;

use Format::Util::Numbers qw(financialrounding);
use List::Util qw(any uniq);
use Scalar::Util qw(looks_like_number);
use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);

use BOM::Config::Runtime;

use constant RISK_THRESHOLDS => ({
        name  => 'yearly_high',
        title => 'Yearly High Risk'
    },
    {
        name  => 'yearly_standard',
        title => 'Yearly Standard Risk'
    },
);

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
    my $self = shift;

    return BOM::Config::Runtime->instance->app_config;
}

=head2 get_risk_thresholds

Get the risk thresholds along with the app_config revision. It takes the following args:

=over 4

=item * type - risk type: I<aml> or I<mt5>

=item * high - list of countries with high risk level.

=back

The return thresholds by broker codes is a hash-ref with the following structure:

{
    revision: ...,
    CR: { high: ..., standard: ...},
    MF: { high: ..., standard: ...}
}

=cut

sub get_risk_thresholds {
    my ($self, $type) = @_;

    die 'Threshold type is missing'    unless $type;
    die "Invalid threshold type $type" unless $type =~ qr/(aml|mt5)/;

    my $app_config = $self->_app_config;
    return {
        decode_json_utf8($app_config->get("compliance.${type}_risk_thresholds"))->%*,
        revision => $app_config->global_revision(),
    };
}

=head2 validate_risk_thresholds

Takes the risk thresholds (AML or MT5) and validates their values. It works with these args:

=over 4

=item * data - A rish thresholds by broker code, represented as a hash

=back

It returns the same thresholds in a hash-ref with finnacial rounding applied.

=cut

sub validate_risk_thresholds {
    my ($self, %values) = @_;

    for my $broker (keys %values) {
        next if $broker eq 'revision';

        my $broker_settings = $values{$broker};
        for my $threshold (RISK_THRESHOLDS) {
            my $value = $broker_settings->{$threshold->{name}};

            if ($value) {
                die "Invalid numeric value for $broker $threshold->{title}: $value\n" unless looks_like_number($value) and $value > 0;
                $value = financialrounding('amount', 'EUR', $value);
            } else {
                $value = undef;
            }
            $broker_settings->{$threshold->{name}} = $value;
        }

        if ($broker_settings->{yearly_high} && $broker_settings->{yearly_standard}) {
            die "Yearly Standard threshold is higher than Yearly High Risk threshold - $broker\n"
                if $broker_settings->{yearly_standard} > $broker_settings->{yearly_high};
        }
    }

    return \%values;
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

    # an auxilary hash for finding duplicate country codes
    my %contry_to_risk_level;

    my $result;
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
