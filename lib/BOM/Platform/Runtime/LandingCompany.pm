package BOM::Platform::Runtime::LandingCompany;

=head1 NAME

BOM::Platform::Runtime::LandingCompany

=head1 SYNOPSYS

    my $iom = BOM::Platform::Runtime::LandingCompany->new(
        short   => 'iom',
        name    => 'Binary (IOM) Ltd',
        address => ["Millennium House", "Victoria Road", "Douglas", "Island"],
        fax     => '+44 555 6667788',
        country => 'Isle of Man',
    );
    say "Fax number is: ", $iom->fax;

=head1 DESCRIPTION

This class represents landing companies objects.

=head1 ATTRIBUTES

=cut

use Moose;
use MooseX::StrictConstructor;
use namespace::autoclean;

use Carp;
use URI;

=head2 short

Short name for the landing company

=cut

has short => (
    is       => 'ro',
    required => 1,
);

=head2 name

Full name of the landing company

=cut

has name => (
    is       => 'ro',
    required => 1,
);

=head2 address

Address of the landing company. Should be arrayref to the list of strings forming the address. Optional.

=cut

has address => (
    is => 'ro',
);

=head2 fax

Landing company's fax number.

=cut

has fax => (
    is       => 'ro',
    required => 1,
);

=head2 country

Country in which landing company registered

=cut

has country => (
    is       => 'ro',
    required => 1,
);

=head2 legal_allowed_currencies

A list of currencies which can legally be traded by this company.

=cut

has legal_allowed_currencies => (
    is      => 'ro',
    isa     => 'ArrayRef[Str]',
    default => sub { [] },
);

=head2 legal_default_currency

The default currency, if any, for this company

=cut

has legal_default_currency => (
    is => 'ro',
);

=head2 legal_default_markets
A list of markets which are allowed on particular landing company
=cut

has legal_allowed_markets => (
    is      => 'ro',
    isa     => 'ArrayRef[Str]',
    default => sub { [] },
);

=head2 legal_allowed_underlyings

A list of underlyings allowed on a particular landing company.
Defaults to 'all', a simple representation of 'all offered'

=cut

has legal_allowed_underlyings => (
    is      => 'ro',
    isa     => 'ArrayRef',
    default => sub { ['all'] },
);

=head2 legal_allowed_contract_types
A list of contract types allowed on a particular landing company
=cut

has legal_allowed_contract_types => (
    is      => 'ro',
    isa     => 'ArrayRef[Str]',
    default => sub { [] },
);

=head2 legal_allowed_contract_categories
A list of contract categories allowed on a particular landing company
=cut

has legal_allowed_contract_categories => (
    is      => 'ro',
    isa     => 'ArrayRef[Str]',
    default => sub { [] },
);

=head2 allows_payment_agents

True if clients allowed to use payment agents

=cut

has allows_payment_agents => (
    is      => 'ro',
    default => 0,
);

has payment_agents_residence_disable => (
    is      => 'ro',
    default => '',
);

has has_reality_check => (
    is      => 'ro',
    default => '',
);

sub is_currency_legal {
    my $self     = shift;
    my $currency = shift;

    return grep { $currency eq $_ } @{$self->legal_allowed_currencies};
}

__PACKAGE__->meta->make_immutable;

1;

=head1 LICENSE AND COPYRIGHT

Copyright 2010 RMG Technology (M) Sdn Bhd

=cut
