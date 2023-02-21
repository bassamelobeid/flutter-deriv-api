package BOM::Config::AccountType::Registry;
use strict;
use warnings;
no indirect ':fatal';

use Syntax::Keyword::Try;
use List::Util qw(uniq none any first);

use BOM::Config;
use BOM::Config::AccountType;
use BOM::Config::AccountType::Category;
use BOM::Config::AccountType::Group;

## VERSION

our (%groups, %categories, %account_types);

=head1 DESCRIPTION

Factory to build instances for account type, account category and group classes.

=cut

=head2 load_data

Loads account types, categories and groups from the configuration file and creates their objects.

=cut

sub load_data {
    my $config = BOM::Config::account_types();

    my $group_config = $config->{groups};
    %groups = map { $_ => BOM::Config::AccountType::Group->new(name => $_, $group_config->{$_}->%*) } keys %$group_config;

    my $category_config = $config->{categories};
    for my $category_name (keys %$category_config) {
        my @category_groups = map { $groups{$_} or die "Unknown group $_ appeared in the account category $category_name"; }
            ($category_config->{$category_name}->{groups}->@*);

        my $category = BOM::Config::AccountType::Category->new(
            $category_config->{$category_name}->%*,
            name          => $category_name,
            account_types => {},
            groups        => \@category_groups,
        );

        my $types_config = $category_config->{$category_name}->{account_types};
        for my $type_name (keys %$types_config) {
            die "Duplicate account type $type_name - please choose unique names for account types" if any { $_->name eq $type_name };
            my @groups = map { $groups{$_} or die "Unknown group $_ appeared in the account type $category_name-$type_name"; }
                ($types_config->{$type_name}->{groups}->@*);

            my $config       = $types_config->{$type_name};
            my $account_type = BOM::Config::AccountType->new(
                %$config,
                name     => $type_name,
                category => $category,
                # category groups are added to account groups
                groups => [sort uniq (@groups, @category_groups)],
            );

            $category->account_types->{$type_name} = $account_type;
            $account_types{$type_name} = $account_type;
        }

        $categories{$category_name} = $category;
    }
}

BEGIN {
    load_data();
}

=head2 group_by_name

Looks for a B<Group> object by name. It takes a single argument:

=over 4

=item * C<$name>: group name

=back

Returns an object of type L<BOM::Config::AccountType::Group>

=cut

sub group_by_name {
    my (undef, $name) = @_;

    die 'Group name is missing' unless $name;

    return $groups{$name};
}

=head2 category_by_name

Looks for a B<Category> object by name. It takes a single argument:

=over 4

=item * C<$name>: category name

=back

Returns an object of type L<BOM::Config::AccountType::Category>

=cut

sub category_by_name {
    my (undef, $name) = @_;

    die 'Category name is missing' unless $name;

    return $categories{$name};
}

=head2 account_type_by_name

Looks for an B<AccountType> object by category and type name. It takes two arguments:

=over 4

=item * C<category>: category name

=item * C<$name>: account type name

=back

Returns an object of type L<BOM::Config::AccountType>

=cut

sub account_type_by_name {
    my (undef, $type) = @_;

    die 'Account type name is missing' unless $type;

    return $account_types{$type};
}

=head2 all_categories

Gets all of the registered categories.

Returns a hash, mapping category names to L<BOM::Config::AccountType::Category> objects.

=cut

sub all_categories {
    return %categories;
}

=head2 find_broker_code

Searches a broker code in account types and categories.
It takes the following named args:

=over 4

=item * C<broker>: broker code

=item * C<category>: category to search (optional)

=item * C<account_type>: account type to search (optional)

Returns 1 if the given borker code exists in the requested account type and category; 0 otherwise.

=back

=cut

sub find_broker_code {
    my (undef, %args) = @_;

    my $broker       = $args{broker} or die "Broker code is missing";
    my $category     = $args{category};
    my $account_type = $args{account_type};

    die "Broker code is missing"                                                unless $broker;
    die "Cannot find the broke code without a category or an account type name" unless $category || $account_type;

    for my $type (values %account_types) {
        next if $account_type && ($type->name ne $account_type);
        next if $category     && ($type->category_name ne $category);
        next if none { $_ eq $broker } map { $type->broker_codes->{$_}->@* } keys $type->broker_codes->%*;

        return 1;
    }

    return 0;
}

1;
