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

has $name                           : reader;
has $category                       : reader;
has $groups                         : reader;
has $services                       : reader;
has $services_lookup                : reader;
has $is_demo                        : reader;
has $linkable_to_different_currency : reader;
has $linkable_wallet_types          : reader;
has $currencies                     : reader;
has $currency_types                 : reader;
has $currencies_by_landing_company  : reader;
has $type_broker_codes              : reader;

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

BUILD {
    my %args = @_;

    $args{$_} //= 0  for (qw/is_demo linkable_to_different_currency/);
    $args{$_} //= [] for (qw/gorups linkable_wallet_types currency_types currencies/);
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
