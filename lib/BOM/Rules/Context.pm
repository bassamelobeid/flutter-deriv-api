package BOM::Rules::Context;

=head1 NAME

BOM::Rules::Context

=head1 DESCRIPTION

The context of the rule engine that determines a common baseline for all B<rules> and B<actions> being applied and verified.

=cut

use strict;
use warnings;

use Moo;
use LandingCompany::Registry;
use Brands;
use BOM::Platform::Context qw(request);

=head2 BUILDARGS

This method overrides the default constructor by initializing the cache and attributes.

=cut

around BUILDARGS => sub {
    my ($orig, $class, %constructor_args) = @_;
    my $client_list = $constructor_args{client_list} // [];

    my %cache = map { "client_" . $_->loginid => $_ } @$client_list;

    my $stop_on_failure = $constructor_args{stop_on_failure} // 1;
    my $siblings        = $constructor_args{siblings}        // {};
    return $class->$orig(
        _cache          => \%cache,
        stop_on_failure => $stop_on_failure,
        client_list     => $client_list,
        siblings        => $siblings,
        action          => $constructor_args{action},
        user            => $constructor_args{user},
    );
};

=head2 clone

Creates a copy of the context object. It is also possible to override the object's attribute by the following named args:

=over 4

item C<client_list> An array-ref of context clients.
item C<siblings> A hash-ref with client loginid as a key and corresponding siblings as value.
item C<stop_on_failure> Rule engine's operation mode (die on failure or report all rules checked)

=back

=cut

sub clone {
    my ($self, %override) = @_;

    return BOM::Rules::Context->new(
        client_list     => $self->client_list,
        siblings        => $self->siblings,
        stop_on_failure => $self->stop_on_failure,
        user            => $self->user,
        %override
    );
}

=head2 client_list

The list of known clients.

=cut

has client_list => (is => 'ro');

=head2 siblings

The hash-ref of known clients siblings.

=cut

has siblings => (
    is      => 'ro',
    default => sub { return +{}; });

=head2 stop_on_failure

Prevents exit on the first failure and perform all actions

=cut

has stop_on_failure => (
    is      => 'ro',
    default => 1
);

=head2 action

The name of the current action.

=cut

has action => (
    is      => 'ro',
    default => ''
);

=head2 user

User object.

=cut

has user => (
    is => 'ro',
);

=head2 _cache

The cache for efficiently loading business objects (clients and landing companies)

=cut

has _cache => (
    is      => 'rw',
    default => sub { return +{}; });

=head2 client

Retrieves a client object from cache by getting a loginid. It accepts one argument:

=over 4

item C<args> event args as a hashref; expected to contain a B<loginid> key.

=back

It returns the corresponding L<BOM::User::Client>; fist from cache, otherwise from  

=cut

sub client {
    my ($self, $args) = @_;

    my $loginid = $args->{loginid};

    die 'Client loginid is missing' unless $loginid;

    # TODO: we can load missing client from database; but it can only be done after the circular dependency to bom-use is resolved.
    my $client = $self->_cache->{"client_$loginid"}
        or die "Client with id $loginid was not found";

    return $client;
}

=head2 client_siblings

Retrieves the siblings list by getting a loginid. It accepts one argument:

=over 4

item C<args> event args as a hashref; expected to contain a B<loginid> key.

=back

It returns an array-ref of corresponding siblings if loginid passed;

=cut

sub client_siblings {
    my ($self, $args) = @_;
    my $loginid = $args->{loginid};

    die 'Client loginid is missing' unless $loginid;

    return $self->siblings->{$loginid};
}

=head2 landing_company_object

Retrieves a landing company object from cache. It accepts one argument:

=over 4

=item C<args> event args as a hashref; expected to contain a B<landing_company> or B<loginid> key.

=back

It returns an object of the type L<LandingCompany>.

=cut

sub landing_company_object {
    my ($self, $args) = @_;
    my $short_code = $self->landing_company($args);

    $self->_cache->{"company_$short_code"} //= LandingCompany::Registry->by_name($short_code);

    my $landing_company = $self->_cache->{"company_$short_code"};
    die "Invalid landing company name $short_code" unless $landing_company;

    return $landing_company;
}

=head2 landing_company

Retrieves a landing company name from input. It accepts one argument:

=over 4

=item C<args> event args as a hashref; expected to contain a B<landing_company> or B<loginid> key.

=back

=cut

sub landing_company {
    my ($self, $args) = @_;
    my $short_code = $args->{landing_company};

    die 'Either landing_company or loginid is required' unless ($short_code || $args->{loginid});

    return $short_code || $self->client($args)->landing_company->short;
}

=head2 get_country

Retrieves a country object from cache by country code. It accepts one argument:

=over 4

=item C<country_code> a country code.

=back

It returns an object of the type L<Country>.

=cut

sub get_country {
    my ($self, $country_code) = @_;

    die 'Country code is required' unless $country_code;

    $self->_cache->{"country_$country_code"} //= Brands->new->countries_instance->countries_list->{$country_code};

    return $self->_cache->{"country_$country_code"};
}

=head2 get_real_sibling

If the client indicted in C<args> is virtual, it will return the earliest real sibling (if there's any);
otherwise it will return the same client object. Arguments:

=over 4

=item C<args> event args as a hashref; expected to contain a B<loginid> key.

=back

=cut

sub get_real_sibling {
    my ($self, $args) = @_;

    die 'Client loginid is missing' unless $args->{loginid};

    my $client = $self->client($args);

    return $client unless ($client and $client->user and not $client->is_virtual);

    #return current client if not virtual
    return $client unless $client->is_virtual;

    my @real_siblings = sort { $b->date_joined cmp $a->date_joined } grep { not $_->is_virtual } $client->user->clients(include_disabled => 0);
    return $real_siblings[0] // $client;
}

=head2 client_type

Returns the client type as a string with three values: virtual,real, none (no context client)

=cut

sub client_type {
    my ($self, $args) = @_;

    die 'Client loginid is missing' unless $args->{loginid};

    my $client = $self->client($args);

    return 'none' unless $client;

    return $client->is_virtual ? 'virtual' : 'real';
}

=head2 residence

Retrieves the name of the country of residence from args. It accepts one argument:

=over 4

=item C<args> event args as a hashref; expected to contain a B<residence> or B<loginid> key.

=back

=cut

sub residence {
    my ($self, $args) = @_;

    die 'Either residence or loginid is required' unless $args->{loginid} // $args->{residence};

    return $args->{residence} // $self->client($args)->residence;
}

=head2 brand

Get the brand object. It accepts one argument:

=over 4

=item C<args> event args as a hashref; expected to contain B<brand> (a brand name).

=back

Returns an object of type L<Brands>.

=cut

sub brand {
    my ($self, $args) = @_;

    return Brands->new(name => $args->{brand});
}

1;
