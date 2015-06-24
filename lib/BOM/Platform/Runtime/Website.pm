package BOM::Platform::Runtime::Website;

=head1 NAME

BOM::Platform::Runtime::Website

=head1 DESCRIPTION

This class represents a Website in our code.

=head1 ATTRIBUTES

=cut

use Moose;
use MooseX::StrictConstructor;
use feature "state";
use Path::Tiny;
use File::Slurp;
use JSON qw(decode_json);

use Data::Hash::DotNotation;

require Locale::Maketext::Lexicon;
use Carp;
use URI;

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

=head2 resource_subdir

The subdirectory name to seperate website specific resources like templates, static files
etc. By default it's the name of the website without whitespaces.

=cut

has resource_subdir => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_resource_subdir {
    my $self   = shift;
    my $subdir = $self->name;
    $subdir =~ s/\s/_/g;
    return $subdir;
}

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

has 'localhost' => (
    is       => 'ro',
    required => 1,
);

has 'features' => (
    is      => 'ro',
    default => sub { []; },
);

has config => (
    is => 'rw',
);

has 'static_path' => (
    is      => 'ro',
    isa     => 'Str',
    default => '/home/git/binary-com/binary-static/',
);

# this is needed for translation to work
has 'static_host' => (
    is      => 'ro',
    isa     => 'Str',
    default => 'binary-com',
);

sub select_broker {
    my $self = shift;
    my $params = shift || {};

    my @brokers;
    if ($params->{virtual}) {
        @brokers = grep {
            $_->is_virtual
                and grep { uc $params->{country} eq $_ }
                @{$_->landing_company->counterparty_for}
        } @{$self->broker_codes} if ($params->{country});
        @brokers = grep {
            $_->is_virtual
                and grep { $_ eq '*' }
                @{$_->landing_company->counterparty_for}
        } @{$self->broker_codes} if (scalar @brokers == 0);
    } else {
        @brokers = grep {
            not $_->is_virtual
                and grep { uc $params->{country} eq $_ }
                @{$_->landing_company->counterparty_for}
        } @{$self->broker_codes} if ($params->{country});
        @brokers = grep {
            not $_->is_virtual
                and grep { $_ eq '*' }
                @{$_->landing_company->counterparty_for}
        } @{$self->broker_codes} if (scalar @brokers == 0);
    }

    my $default_broker = $brokers[0];

    # for Europe, don't default to MF
    if ($default_broker->landing_company->short eq 'maltainvest' and scalar @brokers > 1) {
        $default_broker = $brokers[1];
    }
    return $default_broker;
}

sub broker_for_new_account {
    my $self    = shift;
    my $country = shift;
    return $self->select_broker({country => $country});
}

sub broker_for_new_virtual {
    my $self    = shift;
    my $country = shift;
    return $self->select_broker({
        country => $country,
        virtual => 1
    });
}

sub rebuild_config {
    my $self        = shift;
    my $config_file = path($self->static_path)->child('config.json');
    my $config_json = File::Slurp::read_file($config_file);
    my $json_data   = decode_json($config_json);
    return $self->config(Data::Hash::DotNotation->new(data => $json_data));
}

sub _build_display_name {
    return ucfirst(shift->domain);
}

sub BUILD {
    my $self = shift;
    $self->rebuild_config();
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Arun Murali, C<< <arun at regentmarkets.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2011 RMG Technology (M) Sdn Bhd

=cut
