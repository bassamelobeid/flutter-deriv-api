package BOM::Platform::Runtime;

use Moose;
use MooseX::Types::Common::String qw(NonEmptySimpleStr);
use feature 'state';
use Data::Dumper;

use BOM::Platform::Runtime::AppConfig;
use BOM::System::Host::Registry;
use BOM::System::Host::Role::Registry;
use BOM::Platform::Runtime::LandingCompany::Registry;
use BOM::Platform::Data::Sources;
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

=head2 datasources

Returns an reference to an BOM::Platform::Data::Sources object.
You can get access to various datasources with this.

=cut

has 'datasources' => (
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

=head2 hosts

Returns an reference to an BOM::System::Host::Registry

=cut

has 'hosts' => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 host_roles

Returns an reference to an BOM::System::Host::Role::Registry

=cut

has 'host_roles' => (
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

has 'non_restricted_countries' => (
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
    $instance = $new if ($new);
    $instance ||= $class->new;

    return $instance;
}

sub _build_countries {
    my $self = shift;
    return Locale::Country::Extra->new();
}

sub _build_non_restricted_countries {
    my $self = shift;
    my $bad  = $self->app_config->legal->countries_restricted;
    my %bad  = map { $_ => 1 } @$bad;
    my @good = grep { !$bad{$_} } $self->countries->all_country_names;
    my $countries;
    for my $country (@good) {
        my $code = country2code($country);
        if ($code) {
            $countries->{$code} = $country;
        }
    }
    return $countries;
}

sub _build_countries_list {
    return YAML::XS::LoadFile('/home/git/regentmarkets/bom/config/files/countries.yml');
}

sub country_has_financial {
    my ($self, $country) = @_;
    my $config = $self->countries_list->{$country};
    return unless ($config);

    return ($config and $config->{financial_company} eq 'maltainvest');
}

sub financial_only_country {
    my ($self, $country) = @_;
    my $config = $self->countries_list->{$country};
    return unless ($config);

    return ($config->{gaming_company} eq 'none' and $config->{financial_company} eq 'maltainvest');
}

sub restricted_country {
    my ($self, $country) = @_;
    my $config = $self->countries_list->{$country};
    return 1 unless ($config);

    return ($config->{gaming_company} eq 'none' and $config->{financial_company} eq 'none');
}

sub random_restricted_country {
    my ($self, $country) = @_;
    my $config = $self->countries_list->{$country};
    return 1 unless ($config);

    return ($config->{gaming_company} eq 'none');
}

sub _build_app_config {
    my $self = shift;
    return BOM::Platform::Runtime::AppConfig->new(couch => $self->datasources->couchdb);
}

sub _build_website_list {
    my $self = shift;
    return BOM::Platform::Runtime::Website::List->new(
        broker_codes => $self->broker_codes,
        definitions  => YAML::CacheLoader::LoadFile('/home/git/regentmarkets/bom/config/files/websites.yml'),
        localhost    => $self->hosts->localhost,
    );
}

sub _build_broker_codes {
    my $self = shift;
    return BOM::Platform::Runtime::Broker::Codes->new(
        hosts              => $self->hosts,
        landing_companies  => $self->landing_companies,
        broker_definitions => YAML::CacheLoader::LoadFile('/etc/rmg/broker_codes.yml'));
}

sub _build_datasources {
    my $self = shift;
    return BOM::Platform::Data::Sources->new(hosts => $self->hosts);
}

sub _build_landing_companies {
    return BOM::Platform::Runtime::LandingCompany::Registry->new();
}

sub _build_hosts {
    my $self = shift;
    return BOM::System::Host::Registry->new(
        role_definitions => $self->host_roles,
    );
}

sub _build_host_roles {
    my $self = shift;
    return BOM::System::Host::Role::Registry->new();
}

__PACKAGE__->meta->make_immutable;
1;

=head1 AUTHOR

Nick Marden, C<< <nick at regentmarkets.com> >>

=head1 COPYRIGHT

(c) 2011-, RMG Tech (Malaysia) Sdn Bhd

=cut
