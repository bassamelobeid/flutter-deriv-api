package BOM::Platform::Runtime::Website::List;

use Moose;
use namespace::autoclean;
use Sys::Hostname qw(hostname);

use BOM::Platform::Runtime::Website;
use Carp;

=head1 NAME

BOM::Platform::Runtime::Website::Container

=head1 DESCRIPTION

This role implements all the necessary objects for RuntimeEnvironment
to handle a website.

=head1 ATTRIBUTES

=cut

=head2 default_website

The website object with 'default: 1' setting.

=cut

has 'default_website' => (
    is         => 'ro',
    lazy_build => 1,
);

=head1 METHODS
=head2 get

Get a website by name.

=cut

sub get {
    my $self         = shift;
    my $website_name = shift;

    return $self->_websites->{$website_name};
}

sub all {
    return values %{shift->_websites};
}

=head2 get_by_broker_code

Given a broker code it will return the website that encompases it.

=cut

sub get_by_broker_code {
    my $self   = shift;
    my $broker = shift;

    my $website_by_broker_code = $self->default_website;
    if (not grep { $broker eq $_->code } @{$self->default_website->broker_codes}) {
        foreach my $website (values %{$self->_websites}) {
            if (grep { $broker eq $_->code } @{$website->broker_codes}) {
                $website_by_broker_code = $website;
            }
        }
    }

    return $website_by_broker_code;
}

=head2 choose_website

Returns the best matching website for the given list of parameters.

=cut

sub choose_website {
    my $self = shift;
    my $params = shift || {};

    my @matched;
    if ($params->{backoffice}) {
        @matched = grep { $_->name =~ /BackOffice/ } values %{$self->_websites};
    } else {
        @matched = grep { $_->name !~ /BackOffice/ and $params->{domain_name} and $params->{domain_name} =~ $_->domain } values %{$self->_websites};
    }

    my $result = $self->default_website;
    if (scalar @matched > 0) {
        $result = $matched[0];
    }

    return $result;
}

#
#Build functions
#

has 'definitions' => (
    is       => 'ro',
    required => 1,
);

has 'broker_codes' => (
    is       => 'ro',
    required => 1,
);

has 'localhost' => (
    is       => 'ro',
    required => 1,
);

has '_websites' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__websites {
    my $self = shift;

    my $websites = {};
    for my $website (keys %{$self->definitions}) {
        next if ($website eq 'version');

        my $website_definition = $self->definitions->{$website};

        $website_definition->{name}         = $website;
        $website_definition->{broker_codes} = $self->_broker_objects($website_definition->{broker_codes});
        $website_definition->{localhost}    = $self->localhost;

        if ($website_definition->{primary_url}) {
            my $hostname = hostname;
            $hostname =~ s/\..*//;
            $website_definition->{primary_url} =~ s/_HOST_/$hostname/g;
        }

        $websites->{$website} = BOM::Platform::Runtime::Website->new($website_definition);
    }

    return $websites;
}

sub _build_default_website {
    my $self = shift;

    my $default_website;
    for my $website (values %{$self->_websites}) {
        if ($website->default) {
            return $website;
        }
    }

    croak "No Default website provided, please mention atleast one website as default";
}

sub _broker_objects {
    my $self         = shift;
    my $broker_codes = shift;

    my $brokers = [];
    for my $broker_code (@{$broker_codes}) {
        push @{$brokers}, $self->broker_codes->get($broker_code);
    }

    return $brokers;
}

__PACKAGE__->meta->make_immutable;
1;

=head1 AUTHOR

Arun Murali, C<< <arun at regentmarkets.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2011 RMG Technology (M) Sdn Bhd

=cut
