use Object::Pad;

class BOM::Config::AccountType;

=head1 NAME

BOM::Config::AccountType

=head1 DESCRIPTION

A class representing a an account type. Each account type belongs to a specific B<Category> and a number of B<Groups>.

=cut

use List::Util   qw(any uniq);
use Array::Utils qw( intersect );
use LandingCompany::Registry;
use BOM::Config;
use BOM::Config::Runtime;

use constant {LEGACY_TYPE => 'binary'};

=head1 METHODS - Accessors

=head2 name

Returns the name of account type

=cut

has $name : reader;

=head2 category

Returns the category of account type

=cut

has $category : reader;

=head2 groups

Returns groups (roles) of account type

=cut

has $groups : reader;

=head2 services

Returns services accessible to account type

=cut

has $services : reader;

=head2 services_lookup

An auxiliary lookup table that includes all services in the account type's B<groups>.

Note: It's created for speeding up service lookups needed within internal methods.  It's recommended to use `I<supports_service>  for service lookup everywhere else.

=cut

has $services_lookup : reader;

=head2 linkable_to_different_currency

A boolean flag that tells if the account type can be linked to a wallet with a different currency. The value is false for wallet account types, because they are not linkable to any other wallet.

=cut

has $linkable_to_different_currency : reader;

=head2 linkable_wallet_types

Returns a list of wallet types linkable to the account type. The value I<all> indicates that all wallet types are linkable (which the case for most of the account types). This list should be empty for all wallet account types.

=cut

has $linkable_wallet_types : reader;

=head2 currencies

Returns the currencies allowed for the account type. The list is empty if there is no such limitation.


=cut

has $currencies : reader;

=head2 currency_types

Returns the currency types allowed for the account type. The list is empty if there is no such limitation.

=cut

has $currency_types : reader;

=head2 currencies_by_landing_company

Returns a hash-ref of available currencies per landing company. It's a combination of account type currency limitations introduced by B<currencies> and B<currency_types> and the availability of currencies in landing companies.

=cut

has $currencies_by_landing_company : reader;

=head2 type_broker_codes

Returns a hash-ref of account type's broker codes per landing company. It's usually inherited from the I<account category>, but some account types (like B<affiliate>) override it in their configuration.

=cut

has $type_broker_codes : reader;

=head2 type_platform

Return platform defined at account type level

=cut

has $type_platform : reader;

=head2 regulations

Return list of supported regulations by account type

=cut

has $regulations : reader;

=head2 transfers

Returns type of transfer supported by the account

=cut

has $transfers : reader;

=head2 is_cashier

Returns type of transfer supported by the account

=cut

has $is_cashier : reader = 0;

=head2 is_enabled

Returns status of the account type

=cut

has $is_enabled : reader = 0;

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

=head2 platform 

Return platform for account type, if it's not defined it'll try to take platform from category.

=cut

method platform {
    return $type_platform ? $type_platform : $self->category->platform // '';
}

=head2  new

create account type objects

Takes the following parameters:

=over 4

=item * C<name> - a string that represent the name of account type

=item * C<category> - a L<BOM::config::AccountType::Category> object that represent category

=item * C<supported_regulation> - a list of supported regulation by account type, for example: virtual, svg, maltainvest

=item * C<linkable_to_different_currency> - a bool that indicate it is linkable to a wallet with a different currency

=item * C<groups> - an array ref of groups (roles)

=item * C<linkable_wallet_types> - an array ref of wallet types allowed for linkage (if there's such limitation)

=item * C<currency_types> - an array ref of currency types allowed (if there's such limitation)

=item * C<currencies> - an array ref of allowed currencies (if there's such limitation)

=item * C<broker_code> - an hash ref of broker codes per landing company, if the account type overrides the broker codes of it's B<category>.

=item * C<currencies_by_landing_company> - an hash ref representing the currencies allowed per landing company (if applicable)

=back

Return account type object

=cut

BUILD {
    my %args = @_;

    $args{$_} //= 0  for (qw/linkable_to_different_currency/);
    $args{$_} //= [] for (qw/groups linkable_wallet_types currency_types currencies supported_regulation/);
    $args{$_} //= {} for (qw/broker_codes currencies_by_landing_company/);
    $args{account_opening} //= [qw/demo real/];

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

    $services        = [sort { $a cmp $b } uniq map { $_->services->@* } $args{groups}->@*];
    $services_lookup = +{map { $_ => 1 } @$services};

    my @linkable_wallet_types = ($args{linkable_wallet_types} // [])->@*;

    for my $wallet_type ($args{linkable_wallet_types}->@*) {
        my $wallet_config = BOM::Config->account_types->{categories}->{wallet};

        die "Invalid linkable wallet type $wallet_type in account type $category_name-$name"
            unless $wallet_type eq 'all'
            || $wallet_config->{account_types}->{$wallet_type};
    }

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
                unless any { $_ eq $currency } (keys $landing_company->legal_allowed_currencies->%*);
        }
    }

    $regulations = +{map { $_ => 1 } $args{regulations}->@*};
    $is_cashier  = $args{is_cashier} // 0;
    $is_enabled  = $args{is_enabled} // 0;
    (
        $groups,                        $type_broker_codes, $linkable_to_different_currency,
        $linkable_wallet_types,         $currency_types,    $currencies,
        $currencies_by_landing_company, $type_platform,     $transfers
        )
        = @args{
        qw/groups broker_codes
            linkable_to_different_currency linkable_wallet_types currency_types
            currencies currencies_by_landing_company platform transfers/
        };
}

=head2 get_single_broker_code

It returns the broker code assigned to a landing company in the current account type. It will throw an excpetion if there are more than one broker codes for the landing company, 
in which case we will need an alternative method to choose between the broker codes.
It takes one argument:

=over 4

=item * C<landing_company> the short code of a landing company

=back


Returns a single broker code matching the requested landing company name.

=cut

method get_single_broker_code ($landing_company) {
    die 'Landing company name is missing' unless $landing_company;

    my $broker_codes = $self->broker_codes->{$landing_company} // [];

    die "No broker code found in account type $name for $landing_company" unless scalar @$broker_codes;
    die "Multiple broker codes found in account type $name for $landing_company" if scalar(@$broker_codes) > 1;

    return $broker_codes->[0];
}

=head2 is_account_type_enabled

Predicate checks that regulation is supported by account type

Returns 1 if account type is enabled, otherwise 0

=cut

method is_account_type_enabled {
    return $self->is_enabled ? 1 : 0;
}

=head2 is_regulation_supported

Predicate checks that regulation is supported by account type

=over 4

=item * C<landing_company> the short code of a landing company

=back


Returns 1 if regulation is supported, otherwise 0

=cut

method is_regulation_supported ($landing_company) {
    return $self->regulations->{$landing_company} ? 1 : 0;
}

=head2 is_supported

Predicate checks that account type for requested country and regulation

=over 4

=item * C<brand> instance of C<Brands> object
=item * C<country> 2-letter country code
=item * C<landing_company> the short code of a landing company

=back


Returns 1 if regulation is supported, otherwise 0

=cut

method is_supported ($brand, $country, $landing_company) {
    my $countries = $brand->countries_instance;

    return 0 if $countries->restricted_country($country);

    return 0 unless $self->is_regulation_supported($landing_company);

    my $name = $self->name;

    ### Handlig wallet category ###
    if ($category->name eq 'wallet') {
        if ($name eq 'p2p') {
            my $p2p_config = BOM::Config::Runtime->instance->app_config->payments->p2p;
            return 0 unless $p2p_config->available;

            return 0 if any { $_ eq $country } $p2p_config->restricted_countries->@*;
        }

        for my $type (qw/real virtual/) {
            my $wallet_companies_for_country = $countries->wallet_companies_for_country($country, $type) // [];
            return 1 if any { $_ eq $landing_company } $wallet_companies_for_country->@*;
        }

        return 0;
    }

    ### Handling trading category ###

    my $config_key = +{
        mt5     => 'mt',
        dxtrade => 'dx',
        derivez => 'derivez',
    }->{$name};
    if ($config_key) {
        my $config = $countries->countries_list->{$country}{$config_key};

        # For some wonderful reason we're using real landing companies for real accounts,
        # just looking for any offering for the country, if any we support virtual accounts there
        my $check = $landing_company eq 'virtual' ? sub { shift ne 'none' } : sub { shift eq $landing_company };

        return 0 unless ref $config eq 'HASH';

        MARKET:
        for my $market (values $config->%*) {
            next MARKET unless ref $market eq 'HASH';

            TYPE:
            for my $type (values $market->%*) {
                next TYPE unless $type;

                if (ref $type eq 'ARRAY') {
                    return 1 if any { $check->($_) } $type->@*;
                    next TYPE;
                }

                return 1 if $check->($type);
            }
        }

        return 0;
    }

    if ($name eq 'standard' || $name eq 'binary') {
        return 1 if ($countries->virtual_company_for_country($country)   // '') eq $landing_company;
        return 1 if ($countries->financial_company_for_country($country) // '') eq $landing_company;
        return 1 if ($countries->gaming_company_for_country($country)    // '') eq $landing_company;
    }

    return 0;
}

=head2 get_details

Returns essencial information for account creation with this account type

=over 4

=item * C<landing_company> the short code of a landing company

=item * C<country> the short code of a landing company

=item * C<supported_wallet> Hashref which contains wallet type as a key and any true value as value 

=back


Return hash ref with account type specifc response, for trading types: 

=over 4

=item * C<linkable_to_different_currency> boolean flag, 1 - the account type can be link to wallet with different currency, 0 - if currency must be the same

=item * C<linkable_wallet_types> ArrayRef wich contains supported wallet types

=item * C<allowed_wallet_currencies> ArrayRef which contains currency codes of wallet accounts which the trading account can be linked to

=back

for wallet types: 

=over 4

=item * C<currencies> ArrayRef which contains currencies supported by this wallet type

=back

=cut

method get_details ($landing_company) {
    if ($category->name eq 'trading') {
        return {
            linkable_to_different_currency => $self->linkable_to_different_currency,
            linkable_wallet_types          => $self->linkable_wallet_types,
            allowed_wallet_currencies      => $self->get_currencies($landing_company),
        };
    }

    if ($category->name eq 'wallet') {
        return {currencies => $self->get_currencies($landing_company)};
    }

    die 'Unexpected category: ' . $category->name;
}

=head2 get_currencies

Getter which return list of supported currencies for specific landing company. 
in case of wallet account it's list of currencies which can be used for account creation. 
in case of trading account it's a list of wallet currencies to which account can be linked to.

=over 4

=item * C<company> the short code of a landing company

=back

=cut

method get_currencies ($company) {

    my $lc = LandingCompany::Registry->by_name($company);

    my %allowed_currency       = map { $_ => 1 } $self->currencies->@*;
    my %allowed_currency_types = map { $_ => 1 } $self->currency_types->@*;

    my @currencies;
    for my $currency (sort keys $lc->legal_allowed_currencies->%*) {
        # Hide unsupported currencies
        next if %allowed_currency && !$allowed_currency{$currency};

        my $currency_type = LandingCompany::Registry::get_currency_type($currency);

        # Hide all curencies of unsupported type(fiat/crypto)
        next if %allowed_currency_types && !$allowed_currency_types{$currency_type};

        # Hide suspended crypto currencies
        next if $currency_type eq 'crypto' && BOM::Config::CurrencyConfig::is_crypto_currency_suspended($currency);

        push @currencies, $currency;
    }

    return \@currencies;
}

1;
