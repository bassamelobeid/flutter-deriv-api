use Object::Pad;
class BOM::Config::AccountType;

=head1 NAME

BOM::Config::AccountType

=head1 DESCRIPTION

A class representing a an account type. Each account type belongs to a specific B<Category> and a number of B<Groups>.

=cut


use List::Util qw(any uniq);
use LandingCompany::Registry;
use BOM::Config;

=head1 METHODS - Accessors

=head2 name

Returns the name of account type

=cut

has $name                           : reader;

=head2 category

Returns the category of account type

=cut

has $category                       : reader;

=head2 groups

Returns groups (roles) of account type

=cut

has $groups                         : reader;

=head2 services

Returns services accessible to account type

=cut

has $services                       : reader;

=head2 services_lookup

Returns services lookup of account type

=cut

has $services_lookup                : reader;

=head2 is_demo

Returns a bool value to indicate the account type is demo or not

=cut

has $is_demo                        : reader;

=head2 linkable_to_different_currency

Returns linkable to different currency of account type

=cut


has $linkable_to_different_currency : reader;

=head2 linkable_wallet_types

Returns linkable wallet types of account type

=cut


has $linkable_wallet_types          : reader;

=head2 currencies

Returns currencies of account type

=cut


has $currencies                     : reader;

=head2 currency_types

Returns currency types of account type

=cut

has $currency_types                 : reader;

=head2 currencies_by_landing_company

Returns currencies by landing_company of account type

=cut

has $currencies_by_landing_company  : reader;

=head2 type_broker_codes

Returns type broker codes of account type

=cut

has $type_broker_codes              : reader;

=head1 METHODS

=head2 supports_service

Checks if the account type supports a service.

=over 4

=item * C<$service>: service name. The list of services are available in L<BOM::Config::AccountType::Group::SERVICES>.

=back

Returns 0 or 1.

=cut

method supports_service {
    my $service = shift;

    die 'Service name is missing' unless $service;

    return defined $services_lookup->{$service} ? 1 : 0;
}

=head2 category_name

Get the the name of account type's category.

=cut

method category_name {
    return $category->name;
}

=head2 brands

The list of brands the account type is available in (coming directly from B<Category>).

Returns an array ref of brand names.

=cut

method brands {
    return $self->category->brands;
}

=head2 broker_codes

The broker codes of the account type in landing companies, represented as a hash-ref.
It directly comes from B<Category> by default, but account types can override these defaul values.

=cut

method broker_codes {
    return keys $type_broker_codes->%* ? $type_broker_codes : $self->category->broker_codes // {};
}

=head2  new

create account type objects

Takes the following parameters:

=over 4

=item * C<name> - a string that represent the name of account type

=item * C<category> - a L<BOM::config::AccountType::Category> object that represent category

=item * C<is_demo> - a bool that indicate it is a demo or not

=item * C<linkable_to_different_currency> - a bool that indicate it is linkable to different currency

=item * C<groups> - an array ref of groups

=item * C<linkable_wallet_types> - an array ref of linkable wallet types

=item * C<currency_types> - an array ref of currency types

=item * C<currencies> - an array ref of currencies

=item * C<broker_code> - an hash ref of broker codes

=item * C<currencies_by_landing_company> - an hash ref of landing_company : currencies pairs

=back

Return account type object

=cut

BUILD {
    my %args = @_;

    $args{$_} //= 0  for (qw/is_demo linkable_to_different_currency/);
    $args{$_} //= [] for (qw/groups linkable_wallet_types currency_types currencies/);
    $args{$_} //= {} for (qw/broker_codes currencies_by_landing_company/);

    $name     = $args{name};
    $category = $args{category};

    die "Account type name is missing"                  unless $name;
    die "Category is missing in account type $name"     unless $category;
    die "Invalid category object in account type $name" unless ref $category eq 'BOM::Config::AccountType::Category';

    my $category_name = $category->name;

    die "Duplicate account type $name is being created in category $category_name" if $category->account_types->{$name};

    for my $landing_company (keys $args{broker_codes}->%*) {
        die "Invalid landing company $landing_company in account type $category_name-$name 's broker codes"
            unless LandingCompany::Registry->by_name($landing_company);
    }

    for my $group ($args{groups}->@*) {
        die "Invalid group in account type $category_name-$name" unless ref($group) eq 'BOM::Config::AccountType::Group';
    }

    $services        = [sort {$a cmp $b} uniq map { $_->services->@* } $args{groups}->@* ];
    $services_lookup = +{map { $_ => 1 } @$services};

    my @all_real_wallets =
        grep { $_ ne 'demo' } keys BOM::Config->account_types->{categories}->{wallet}->{account_types}->%*;

    my @linkable_wallet_types = ($args{linkable_wallet_types} // [])->@*;

    for my $wallet_type ($args{linkable_wallet_types}->@*) {
        my $wallet_config = BOM::Config->account_types->{categories}->{wallet};

        die "Invalid linkable wallet type $wallet_type in account type $category_name-$name"
            unless $wallet_type eq 'all'
            || $wallet_config->{account_types}->{$wallet_type};

        die "Demo account type $category_name-$name is linked to non-demo wallet $wallet_type" if $args{is_demo} && $wallet_type ne 'demo';
    }
    @linkable_wallet_types = @all_real_wallets if any {$_ eq 'all'} $args{linkable_wallet_types}->@*;

    $args{linkable_wallet_types} = \@linkable_wallet_types;

    for my $currency ($args{currencies}->@*) {
        die "Unknown currency $currency in account type $category_name-$name 's limited correncies"
            unless LandingCompany::Registry::get_currency_definition($currency);
    }

    for my $currency_type ($args{currency_types}->@*) {
        die "Unknown currency type $currency_type in account type $category_name-$name 's limited currency types"
            unless $currency_type =~ qr/fiat|crypto/;
    }

    for my $company_name (keys $args{currencies_by_landing_company}->%*) {
        my $landing_company = LandingCompany::Registry->by_name($company_name);
        die "Invalid landing company $company_name in account type $category_name-$name 's limited currencies"
            unless $landing_company;

        for my $currency ($args{currencies_by_landing_company}->{$company_name}->@*) {
            die "Invalid currency $currency in account type $category_name-$name 's landing company limited currencies for $company_name"
                unless any {$_ eq $currency} (keys $landing_company->legal_allowed_currencies->%*);
        }
    }

    (
        $groups,                 $type_broker_codes, $is_demo,    $linkable_to_different_currency,
        $linkable_wallet_types, $currency_types,    $currencies, $currencies_by_landing_company
        )
        = @args{
        qw/groups broker_codes
            is_demo linkable_to_different_currency linkable_wallet_types currency_types
            currencies currencies_by_landing_company/
        };
};

1;
