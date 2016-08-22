package BOM::Platform::Countries;

use Moose;
use feature 'state';

use BOM::Platform::LandingCompany::Registry;
use YAML::XS;
use Locale::Country::Extra;
use Locale::Country;

has 'countries' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'countries_list' => (
    is         => 'ro',
    lazy_build => 1,
);

my $instance;

BEGIN {
    $instance = __PACKAGE__->new;
}

sub instance {
    my ($class, $new) = @_;
    $instance = $new if (defined $new);

    return $instance;
}

my $countries;

BEGIN {
    $countries = Locale::Country::Extra->new();
}

sub _build_countries {
    my $self = shift;
    return $countries;
}

my $countries_list;

BEGIN {
    $countries_list = YAML::XS::LoadFile('/home/git/regentmarkets/bom-platform/config/countries.yml');
}

sub _build_countries_list {
    return $countries_list;
}

sub financial_company_for_country {
    my ($self, $country) = @_;
    my $config = $country && $self->countries_list->{$country};
    return if (not $config or $config->{financial_company} eq 'none');

    return $config->{financial_company};
}

sub gaming_company_for_country {
    my ($self, $country) = @_;
    my $config = $country && $self->countries_list->{$country};
    return if (not $config or $config->{gaming_company} eq 'none');

    return $config->{gaming_company};
}

sub virtual_company_for_country {
    my ($self, $country) = @_;
    my $config = $country && $self->countries_list->{$country};
    return unless $config;

    my $company = ($config->{virtual_company}) ? $config->{virtual_company} : 'virtual';
    return $company;
}

sub restricted_country {
    my ($self, $country) = @_;
    my $config = $country && $self->countries_list->{$country};
    return 1 unless ($config);

    return ($config->{gaming_company} eq 'none' and $config->{financial_company} eq 'none');
}

sub volidx_restricted_country {
    my ($self, $country) = @_;
    my $config = $country && $self->countries_list->{$country};
    return 1 unless ($config);

    return ($config->{gaming_company} eq 'none');
}

sub financial_binaries_restricted_country {
    my ($self, $country) = @_;
    my $config = $country && $self->countries_list->{$country};
    return 1 unless ($config);

    return ($config->{financial_company} eq 'none');
}

__PACKAGE__->meta->make_immutable;
1;
