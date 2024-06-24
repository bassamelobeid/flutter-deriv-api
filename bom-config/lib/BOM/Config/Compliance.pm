package BOM::Config::Compliance;

use strict;
use warnings;
no indirect;

=head1 NAME

C<BOM::Config::Compliance>

=head1 DESCRIPTION

This module implements methods to easily load and save global compliance-related settings.

=cut

use Format::Util::Numbers qw(financialrounding);
use List::Util            qw(any uniq none);
use Scalar::Util          qw(looks_like_number);
use JSON::MaybeUTF8       qw(decode_json_utf8 encode_json_utf8);

use LandingCompany::Registry;
use Business::Config::LandingCompany::Registry;
use BOM::Config::Runtime;

use constant RISK_THRESHOLDS => ({
        name  => 'yearly_standard',
        title => 'Yearly Standard Risk'
    },
    {
        name  => 'yearly_high',
        title => 'Yearly High Risk'
    },
);

use constant RISK_LEVELS => qw/standard high restricted/;
# adding a new risk contstant for threshold levels
# this is different from aml risk levels due to additonal "restricted" level
use constant RISK_THRESHOLDS_LEVELS => qw/standard high/;
use constant RISK_AML_LEVELS        => qw/standard high/;

=head2 new

Class constructor.

Example:

    my $compliance_comfig = BOM::Config::Compliance->new();

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

=item * C<$type> - risk type: I<aml> or I<mt5>

=back

The return thresholds by broker codes is a hash-ref with the following structure:

{
    revision: ...,
    svg: { restricted: ..., high: ..., standard: ...},
    maltainvest: { restricted: ..., high: ..., standard: ...}
}

=cut

sub get_risk_thresholds {
    my ($self, $type) = @_;

    die 'Threshold type is missing'    unless $type;
    die "Invalid threshold type $type" unless $type =~ qr/^(aml|mt5)$/;

    my $app_config = $self->_app_config;
    my %config     = decode_json_utf8($app_config->get("compliance.${type}_risk_thresholds"))->%*;

    # We used to save AML risk thresholds by broker code. In order to avoid data loss,
    # broker codes are converted to landing company short names. This part can be removed if settings are rewritten once from the compliance dashboard backoffice.
    for my $code (keys %config) {
        my $lc = LandingCompany::Registry->by_broker($code);
        if ($lc) {
            $config{$lc->short} = $config{$code};
            delete $config{$code};
        }
    }

    my @valid_landing_companies = grep { $_->risk_lookup->{"${type}_thresholds"} } LandingCompany::Registry->get_all;

    my $result;
    for my $lc (@valid_landing_companies) {
        $result->{$lc->short}->{"yearly_$_"} = $config{$lc->short}->{"yearly_$_"} for RISK_THRESHOLDS_LEVELS;
    }

    $result->{revision} = $app_config->global_revision;
    return $result;
}

=head2 validate_risk_thresholds

Takes the aml risk thresholds and validates their values. It works with these args:

=over 4

=item * C<%values> - risk thresholds by broker code, represented as a hash; for example:

( svg => {standard => 10000, high => 20000}, maltainvest => {standard => 10000, high => 20000}, ... )

=back

It returns the same thresholds in a hash-ref with financial rounding applied.

=cut

sub validate_risk_thresholds {
    my ($self, $type, %values) = @_;

    my @valid_landing_companies = grep { $_->risk_lookup->{"${type}_thresholds"} } LandingCompany::Registry->get_all;

    # Broker codes are converted to landing company short names (for backward compatibility)
    for my $code (keys %values) {
        my $lc = LandingCompany::Registry->by_broker($code);
        if ($lc) {
            $values{$lc->short} = $values{$code};
            delete $values{$code};
        }
    }

    for my $landing_company (keys %values) {
        next if $landing_company eq 'revision';

        die "AML risk thresholds are not applicable to the landing company $landing_company"
            if none { $landing_company eq $_->short } @valid_landing_companies;

        my $lc_settings = $values{$landing_company};
        for my $threshold (RISK_THRESHOLDS) {
            my $value = $lc_settings->{$threshold->{name}};

            if ($value) {
                die "Invalid numeric value for $landing_company $threshold->{title}: $value\n" unless looks_like_number($value) and $value > 0;
                $value = financialrounding('amount', 'EUR', $value);
            } else {
                $value = undef;
            }
            $lc_settings->{$threshold->{name}} = $value;
        }

        if ($lc_settings->{yearly_high} && $lc_settings->{yearly_standard}) {
            die "Yearly Standard threshold is higher than Yearly High Risk threshold - $landing_company\n"
                if $lc_settings->{yearly_standard} > $lc_settings->{yearly_high};
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

Example:

    my $compliance_config = BOM::Config::Compliance->new();
    my $result            = $compliance_config->get_jurisdiction_risk_rating('aml');

Returns a hashref with the following structure:

{ revision => ..., maltainvest => {standard => [...], hight => [...]},  bvi => {standard => [...], hight => [...]}, ... } 

=cut

sub get_jurisdiction_risk_rating {
    my ($self, $type) = @_;

    die 'Threshold type is missing'    unless $type;
    die "Invalid threshold type $type" unless $type =~ qr/^(aml|mt5)$/;

    my $app_config = $self->_app_config;
    my $config     = decode_json_utf8($app_config->get("compliance.${type}_jurisdiction_risk_rating"));

    my @valid_landing_companies = grep { scalar $_->risk_lookup->{"${type}_jurisdiction"} } LandingCompany::Registry->get_all;

    # Output structure is the same as app_config's; but it will contain all landing companies and risk levels (even if country lists are empty).
    # The data is ready to show and edit in backoffice.
    my $result;
    for my $lc (@valid_landing_companies) {
        next if none { $_ eq "${type}_jurisdiction" } $lc->risk_settings->@*;

        $config->{$lc->short}->{$_} //= [] for RISK_LEVELS;
        $result->{$lc->short}->{$_} = [sort $config->{$lc->short}->{$_}->@*] for RISK_LEVELS;
    }

    $result->{revision} = $app_config->global_revision;
    return $result;
}

=head2 validate_jurisdiction_risk_rating

Saves the country lists assigned to jurisdiction risk levels. It also validates the input and reutrns an error message on failure.
It accepts the risk ratings in the following format:

( revision => ..., maltainvest => {standard => [...], hight => [...]},  bvi => {standard => [...], hight => [...]}, ... )

It returns the same structure as a hash-ref with sorted, unique country lists.

=cut

sub validate_jurisdiction_risk_rating {
    my ($self, $type, %args) = @_;

    my $result = {};

    my @valid_landing_companies = grep { scalar $_->risk_lookup->{"${type}_jurisdiction"} } LandingCompany::Registry->get_all;

    for my $lc (keys %args) {
        next if $lc eq 'revision';

        die "Jursdiction risk ratings are not applicable to the landing company $lc" if none { $lc eq $_->short } @valid_landing_companies;

        # an auxilary hash for finding duplicate country codes
        my %country_to_risk_level;

        for my $risk_level (RISK_LEVELS) {
            my @country_list = uniq $args{$lc}->{$risk_level}->@*;

            for my $country (@country_list) {
                next unless $country;
                if ($country_to_risk_level{$country}) {
                    die
                        "Duplicate country found in $lc jurisdiction ratings: <$country> appears both in $country_to_risk_level{$country} and $risk_level listings\n";
                } else {
                    $country_to_risk_level{$country} = $risk_level;
                }

                die "Invalid country code <$country> in $risk_level risk listing\n" unless $self->_countries->country_from_code($country);
            }
            $result->{$lc}->{$risk_level} = [sort @country_list];
        }
    }

    return $result;
}

=head2 get_npj_countries_list

Gets list of countries categorized by their landing company name that are NPJ.

=cut

sub get_npj_countries_list {

    my ($self) = @_;

    my $app_config = $self->_app_config;
    my $config     = decode_json_utf8($app_config->get("compliance.npj_country_list"));

    $config->{revision} = $app_config->global_revision;

    return $config;
}

=head2 is_tin_required

Check if the country and landing company requires TIN.

Takes the following parameters:

=over 4

=item * C<landing_company> - landing company short code

=item * C<country> - 2-letter country code. If not provided, it will use 'default' value.

=back

To check if TIN is required, checks if the country is a Non Participating Jurisdiction (NPJ) for the provided landing company.
    - If the country is NPJ, TIN is not required.
    - If the country is PJ, TIN is required.

=cut

sub is_tin_required {
    my ($self, $country, $lc_short) = @_;

    die 'no country'         unless $country;
    die 'no landing_company' unless $lc_short;

    my $npj_countries = $self->get_npj_countries_list;

    return 0 if any { $country eq $_ } $npj_countries->{$lc_short}->@*;

    my $lc = Business::Config::LandingCompany::Registry->new->by_code($lc_short);
    return 0 unless $lc;
    my $lc_requirements = $lc->requirements;

    return 0 unless $lc_requirements->{compliance}->{tax_information};

    return 1;
}

=head2 validate_npj_country_list
validate input country codes
lower case
2 character lenght
valid country (cross check with our country list)
repeated values
=cut

sub validate_npj_country_list {
    my ($self, @countries) = @_;
    my %counter;

    return "duplicate values detected" if grep { ++$counter{$_} == 2 } @countries;

    for my $country (@countries) {

        return "Invalid country code <$country> in NPJ Country List\n"
            unless $self->_countries->country_from_code($country)
            && length($country) == 2
            && $country eq lc $country;
    }
}

1;
