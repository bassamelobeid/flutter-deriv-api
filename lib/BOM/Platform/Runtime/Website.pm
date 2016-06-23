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
