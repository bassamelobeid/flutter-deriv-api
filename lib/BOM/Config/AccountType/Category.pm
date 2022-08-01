use Object::Pad;
class BOM::Config::AccountType::Category;


=head1 NAME

BOM::Config::AccountType::Category

=head1 DESCRIPTION

A class representing a an account category.

=cut

use List::Util qw(any);
use Brands;



has $name          : reader;
has $broker_codes  : reader;
has $account_types : reader;
has $brands        : reader;
has $groups        : reader;

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
