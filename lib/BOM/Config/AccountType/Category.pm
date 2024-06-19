use Object::Pad;

class BOM::Config::AccountType::Category;

=head1 NAME

BOM::Config::AccountType::Category

=head1 DESCRIPTION

A class representing a an account category.

=cut

use List::Util qw(any);
use Brands;

=head1 METHODS - Accessors

=head2 name

Returns the name of account category

=cut

field $name : reader;

=head2 broker_codes

Returns a hash-ref containing the broker codes per landing company.

=cut

field $broker_codes : reader;

=head2 platform

Platform defined at category level

=cut

field $platform : reader;

=head2 account_types

Returns account types included in the current category as a hash ref of name:L<BOM::Config::AccountType> pairs

=cut

field $account_types : reader;

=head2 brands

Returns a list of brands that the account type is available for

=cut

field $brands : reader;

=head2 groups

Returns groups (roles) of the account category. These groups are shared among all included account types and appear in their list of B<groups>.

=cut

field $groups : reader;

=head1 METHODS

=head2 new

Create account category object

Takes the following parameters:

=over 4

=item * C<name> -  a string that represent the name of account category

=item * C<groups> - an arrayref of L<BOM::Config::AccountType::Group> objects (or roles)

=item * C<brands> - an arrayref of brand names within which the category is activated.

=item * C<broker_codes> - a hashref of broker_codes per landing company

=item * C<account_types> -contains all included account types a hashref of name : L<BOM::Config::AccountType> pairs

=back

Returns a L<BOM::config::AccountType::Category> object

=cut

BUILD {
    my %args = @_;

    $name = $args{name};
    die "Category name is missing" unless $name;

    for my $group ($args{groups}->@*) {
        die "Invalid group in account category $name" unless ref($group) eq 'BOM::Config::AccountType::Group';
    }

    for my $brand ($args{brands}->@*) {
        die "Invalid brand name $brand in account category $name" unless any { $_ eq $brand } Brands::allowed_names()->@*;
    }

    for my $landing_company (keys $args{broker_codes}->%*) {
        die "Invalid landing company $landing_company in account category $name 's broker codes"
            unless LandingCompany::Registry->by_name($landing_company);
    }

    for my $type_name (keys $args{account_types}->%*) {
        my $account_type = $args{account_types}->{$type_name};

        die "Invalid object for the account type $type_name in category $name" unless ref($account_type) eq 'BOM::Config::AccountType';
        die "Incorrect account type name $type_name in category $name - correct name is: " . $account_type->name
            unless $type_name eq $account_type->name;
        die "Invalid category name " . $account_type->category_name . " found in account type $type_name. The expected category name was $name"
            unless $name eq $account_type->category_name;
    }

    ($brands, $broker_codes, $account_types, $groups, $platform) = @args{qw/brands broker_codes account_types groups platform/};
}

=head2 get_account_types_for_regulation

Method return list of supported account types for specifc landing company and country

=over 4

=item * C<landing_company> the short code of a landing company

=item * C<country> 2-letter country code

=item * C<brand> instance of C<Brands> object

=back

=cut 

method get_account_types_for_regulation ($landing_company, $country, $brand) {
    my @supported_account_types;

    my $account_types = $self->account_types;

    for my $type (values $account_types->%*) {
        next unless $type->is_supported($brand, $country, $landing_company);
        push @supported_account_types, $type;
    }

    return \@supported_account_types;
}

1;
