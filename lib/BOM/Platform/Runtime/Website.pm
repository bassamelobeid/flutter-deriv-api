package BOM::Platform::Runtime::Website;

=head1 NAME

BOM::Platform::Runtime::Website

=head1 DESCRIPTION

This class represents a Website in our code.

=head1 ATTRIBUTES

=cut

use Moose;
use MooseX::StrictConstructor;
use Path::Tiny;
use JSON qw(decode_json);
use List::Util qw(first);
use Carp;
use URI;

require Locale::Maketext::Lexicon;

=head2 name

The name for the website

=cut

has name => (
    is  => 'ro',
    isa => 'Str',
);

has display_name => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 primary_url

This is the primary url for this website.

=cut

has primary_url => (
    is  => 'ro',
    isa => 'Str',
);

=head2 broker_codes

The list of broker codes that can be used by this website

=cut

has broker_codes => (
    is  => 'ro',
    isa => 'ArrayRef[BOM::Platform::Runtime::Broker]',
);

=head2 reality_check_broker_codes

The list of broker codes that is subject to reality check on this website

=cut

has reality_check_broker_codes => (
    is         => 'ro',
    isa        => 'ArrayRef[BOM::Platform::Runtime::Broker]',
    lazy_build => 1,
);

sub _build_reality_check_broker_codes {
    my $self = shift;

    my %matches;
    for my $br (@{$self->broker_codes}) {
        $matches{$br->code} = $br if $br->landing_company->has_reality_check;
    }

    return [values %matches];
}

=head2 reality_check_interval

The reality check interval in minutes on this website

=cut

has reality_check_interval => (
    is      => 'ro',
    isa     => 'Int',
    default => 60,
);

=head2 preferred_for_countries

The list of countries for whom we have to show this website instead of the other subset.

=cut

has preferred_for_countries => (
    is      => 'ro',
    isa     => 'ArrayRef[Str]',
    default => sub { [] },
);

=head2 filtered_currencies

This list defines the list of currencies supported by this website.

=cut

has filtered_currencies => (
    is      => 'ro',
    isa     => 'ArrayRef[Str]',
    default => sub { [] },
);

has domain => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => sub {
        my $self = shift;
        my ($domain) = ($self->primary_url =~ /^[a-zA-Z0-9\-]+\.([a-zA-Z0-9\-]+\.[a-zA-Z0-9\-]+)$/);
        return $domain;
    },
);

=head2 default

Is this the default website

=cut

has default => (
    is => 'ro',
);

has 'default_language' => (
    is      => 'ro',
    default => 'EN'
);

sub broker_for_new_account {
    my ($self, $country_code) = @_;

    my $company = BOM::Platform::Runtime->instance->gaming_company_for_country($country_code);
    $company //= BOM::Platform::Runtime->instance->financial_company_for_country($country_code);

    # For restricted countries without landing company (eg: Malaysia, US), default to CR
    # As without this, accessing www.binary.com from restricted countries will die
    # This needs refactor later
    $company //= 'costarica';
    my $broker = first { $_->landing_company->short eq $company } @{$self->broker_codes};

    return $broker;
}

sub broker_for_new_financial {
    my $self         = shift;
    my $country_code = shift;

    my $broker;
    if (my $company = BOM::Platform::Runtime->instance->financial_company_for_country($country_code)) {
        $broker = first { $_->landing_company->short eq $company } @{$self->broker_codes};
    }
    return $broker;
}

sub broker_for_new_virtual {
    my ($self, $country_code) = @_;

    my $vr_broker;
    if (my $vr_company = BOM::Platform::Runtime->instance->virtual_company_for_country($country_code)) {
        $vr_broker = first { $_->landing_company->short eq $vr_company } @{$self->broker_codes};
    }
    return $vr_broker;
}

sub _build_display_name {
    return ucfirst(shift->domain);
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Arun Murali, C<< <arun at regentmarkets.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2011 RMG Technology (M) Sdn Bhd

=cut
