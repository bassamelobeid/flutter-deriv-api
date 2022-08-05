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

Returns the name of account type category

=cut

has $name          : reader;

=head2 broker_codes

Returns broker codes of account type category

=cut


has $broker_codes  : reader;

=head2 account_types

Returns account types of name of account type category

=cut


has $account_types : reader;

=head2 brands

Returns brands of account type category

=cut


has $brands        : reader;

=head2 groups

Returns groups of account type category

=cut

has $groups        : reader;

=head1 METHODS

=head2 new

Create account type category object

Takes the following parameters:

=over 4

=item * C<name> -  a string that represent the name of account type category

=item * C<groups> - an arrayref of L<BOM::Config::AccountType::Group> objects

=item * C<brands> - an arrayref of brand names

=item * C<broker_codes> - a hashref of landing company : broker_codes pairs

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
        die "Incorrect account type name $type_name in category $name - correct name is: ". $account_type->name unless $type_name eq $account_type->name;
        die "Invalid category name " . $account_type->category_name . " found in account type $type_name. The expected category name was $name"
            unless $name eq $account_type->category_name;
    }

    ($brands, $broker_codes, $account_types, $groups) = @args{qw/brands broker_codes account_types groups/};
}

1;
