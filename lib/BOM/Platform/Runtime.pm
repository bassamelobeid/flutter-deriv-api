package BOM::Platform::Runtime;

use Moose;
use MooseX::Types::Common::String qw(NonEmptySimpleStr);
use feature 'state';
use Data::Dumper;

use BOM::Platform::Runtime::AppConfig;
use BOM::Platform::Runtime::LandingCompany::Registry;
use BOM::Platform::Runtime::Broker::Codes;
use BOM::Platform::Runtime::Website::List;
use YAML::XS;
use Locale::Country::Extra;
use Locale::Country;

use BOM::System::Types qw(bom_language_code);

=head1 NAME

BOM::Platform::Runtime

=head1 SYNOPSIS

  use BOM::Platform::Runtime;

  my $website = BOM::Platform::Runtime->instance->website_list->get('Binary') #Gets the Binary website.

=head1 ATTRIBUTES

=head2 app_config

Returns an reference to an BOM::Platform::Runtime::AppConfig object.

=cut

has 'app_config' => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 website_list

Returns an reference to an BOM::Platform::Runtime::Website::List object.

=cut

has 'website_list' => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 broker_codes

Returns an reference to an BOM::Platform::Runtime::Broker::Codes object.

=cut

has 'broker_codes' => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 landing_companies

Returns an reference to an BOM::Platform::Runtime::LandingCompany::Registry

=cut

has 'landing_companies' => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 countries

Returns an reference to a Locale::Country::Extra object.

=cut

has 'countries' => (
    is         => 'ro',
    lazy_build => 1,
);

has 'countries_list' => (
    is         => 'ro',
    lazy_build => 1,
);

=head1 METHODS

=head2 instance

Returns an active instance of the object.

It actively maintains instance of object using state functionality of perl.
This means this class is not a singleton but has capabilities to maintain a single
copy across the system's execution environment.

=cut

sub instance {
    my ($class, $new) = @_;
    state $instance;
    $instance = $new if (defined $new);
    $instance ||= $class->new;

    return $instance;
}

sub _build_countries {
    my $self = shift;
    return Locale::Country::Extra->new();
}

sub _build_countries_list {
    return YAML::XS::LoadFile('/home/git/regentmarkets/bom-platform/config/countries.yml');
}

sub financial_company_for_country {
    my ($self, $country) = @_;
    my $config = $self->countries_list->{$country};
    return if (not $config or $config->{financial_company} eq 'none');

    return $config->{financial_company};
}

sub gaming_company_for_country {
    my ($self, $country) = @_;
    my $config = $self->countries_list->{$country};
    return if (not $config or $config->{gaming_company} eq 'none');

    return $config->{gaming_company};
}

sub virtual_company_for_country {
    my ($self, $country) = @_;
    my $config = $self->countries_list->{$country};
    return unless $config;

    my $company = ($config->{virtual_company}) ? $config->{virtual_company} : 'fog';
    return $company;
}

sub restricted_country {
    my ($self, $country) = @_;
    my $config = $self->countries_list->{$country};
    return 1 unless ($config);

    return ($config->{gaming_company} eq 'none' and $config->{financial_company} eq 'none');
}

sub volidx_restricted_country {
    my ($self, $country) = @_;
    my $config = $self->countries_list->{$country};
    return 1 unless ($config);

    return ($config->{gaming_company} eq 'none');
}

sub _build_app_config {
    my $self = shift;
    return BOM::Platform::Runtime::AppConfig->new();
}

sub _build_website_list {
    my $self = shift;
    return BOM::Platform::Runtime::Website::List->new(
        broker_codes => $self->broker_codes,
        definitions  => YAML::XS::LoadFile('/home/git/regentmarkets/bom-platform/config/websites.yml'),
    );
}

sub _build_broker_codes {
    my $self = shift;
    return BOM::Platform::Runtime::Broker::Codes->new(
        landing_companies  => $self->landing_companies,
        broker_definitions => YAML::XS::LoadFile('/etc/rmg/broker_codes.yml'));
}

sub _build_landing_companies {
    return BOM::Platform::Runtime::LandingCompany::Registry->new();
}

__PACKAGE__->meta->make_immutable;
1;

=head1 AUTHOR

Nick Marden, C<< <nick at regentmarkets.com> >>

=head1 COPYRIGHT

(c) 2011-, RMG Tech (Malaysia) Sdn Bhd

=cut
