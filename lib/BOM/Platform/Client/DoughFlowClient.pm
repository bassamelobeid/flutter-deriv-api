package BOM::Platform::Client::DoughFlowClient;

=head1 NAME

DoughFlowClient.pm

=head1 SYNOPSIS

my $doughflow_client = BOM::Platform::Client::DoughFlowClient->new({'loginid' => 'CR5066'});

=head1 DESCRIPTION

The Dough Flow integration has some specific requirements for its Client fields.

Specifically for the GetCustomer API.

This class coerces our existing Client data into a form that DoughFlow will accept.

It is now a Rose::DB::Object derived class so all Client table columns are available as get/sets.

=cut

use strict;
use warnings;

use base qw(BOM::User::Client);

use Locale::Country;
use Lingua::EN::AddressParse;
use Date::Utility;

# The currently suppoted country names and codes are:
#     AU or Australia
#     CA or Canada
#     GB or United Kingdom
#     US or United States

=head1 METHODS

=cut

# property bag for DoughFlow CreateCustomer API
# requires SportsBook, SecurePassCode, IP, and hash key as "password"
sub create_customer_property_bag {
    my $self = shift;
    my $args = shift;

    my $property_bag = {
        SecurePassCode => $args->{'SecurePassCode'},
        Sportsbook     => $args->{'Sportsbook'},
        IP_Address     => $args->{'IP_Address'},
        Password       => $args->{'Password'},
        PIN            => $self->loginid,
        CustName       => $self->CustName,
        City           => $self->City,
        Street         => $self->Street,
        Province       => $self->Province,
        PCode          => $self->PCode,
        Country        => $self->Country,
        Phone          => $self->Phone,
        DOB            => $self->DOB,
        Email          => $self->Email,
        Gender         => $self->Gender,
        Profile        => $self->Profile,
    };
    return $property_bag;
}

# CustName
# The trimmed full name must be a minimum of 4 characters long with a space separating at least the first and last name.
# Eg.
# john smith  OK
# ty jo OK
# a a  NOT OK
sub CustName {
    my $self = shift;

    my $name = $self->first_name . ' ' . $self->last_name;
    if ($name ne " ") {    # We should not pad a non-existent name. That would mask doughflow errors.
        $name .= 'X' while length $name < 4;    # pads the name out to 4 characters.
    }
    return $name;
}

# Parsed Address
sub _parse_address {
    my $self = shift;

    if (not $self->{'_parsed_address'}) {
        my $add_in_str = join("\n", $self->address_1, $self->address_2, $self->city, $self->state, $self->postcode);
        $add_in_str = uc($add_in_str);

        my %args = (
            country               => Locale::Country::code2country($self->residence),
            auto_clean            => 1,
            force_case            => 1,
            abbreviate_subcountry => 1,
        );
        my $address = Lingua::EN::AddressParse->new(%args);
        my $error   = $address->parse($add_in_str);

        my %components = $address->components;
        $self->{'_parsed_address'}       = \%components;
        $self->{'_parsed_address_error'} = $error;
    }
    return $self->{'_parsed_address'};
}

# Street
# The trimmed Street must be more than 1 character long
sub Street { return shift->address_1 }

# City
# The trimmed City name must be at least 2 characters long
sub City {
    my $self = shift;

    my $city = $self->city;

    if ($self->Country eq 'US' or $self->Country eq 'CA' or $self->Country eq 'AU' or $self->Country eq 'GB') {
        $self->_parse_address;
        $city = $self->{'_parsed_address'}->{'suburb'}
            unless $self->{'_parsed_address_error'};
    }

    if ($city) {    # We should not pad a non-existent city. That would mask doughflow errors.
        $city .= 'X' while length $city < 2;    # pads the name out to 2 characters.
    }
    return $city;
}

# Province
# If the Country is US, CA or AU, then the Province is required. Uses the 2 character ISO code. For Australia, DoughFlow supports the 2 and 3 character ISO standard. The selected Province MUST correspond to the selected country.
# Eg.
# CA, US  OK
# AB, US  NOT OK
# <blank>, CA NOT OK
sub Province {
    my $self = shift;

    my $province;
#       Lingua::EN::AddressParse will get provinces from:
#     AU or Australia
#     CA or Canada
#     GB or United Kingdom
#     US or United States

    if ($self->Country eq 'US' or $self->Country eq 'CA' or $self->Country eq 'AU' or $self->Country eq 'GB') {
        # must be US state
        # 2-letter iso code
        $self->_parse_address;
        if (not $self->{'_parsed_address_error'}) {
            $province = $self->{'_parsed_address'}->{'subcountry'};
        } else {
            # this will be blank for most clients until
            # the DF forward forces them to fill it
            $province = $self->state;
        }
    } else {
        $province = $self->state;
    }

    if ($self->Country eq 'GB') {
        $province = '';
    }
    return $province;
}

# Country
# Must use the standard 2 character ISO code for country
sub Country { return uc shift->residence }

# PCode
# Postal Code is required if the Country is US or CA. All spaces, dashes are to be removed. US postal code format must be either 5 or 9 digit. CA postal code format must be of ANANAN where A is an alphabetic character and N is a numeric.
# Eg.
# 12345 OK (US)
# 123451234 OK (US)
# 12345-1234  NOT OK (US)
# 12345 1234 NOT OK (US)
# T5T0M2 OK (CA)
# T5T 0M2 NOT OK (CA)
# T5T-0M2 NOT OK (CA)PCode
# Postal Code is required if the Country is US or CA. All spaces, dashes are to be removed. US postal code format must be either 5 or 9 digit. CA postal code format must be of ANANAN where A is an alphabetic character and N is a numeric.
sub PCode { return shift->postcode }

# Phone
# Only numeric digits allowed (0-9). All non-numerics are stripped. Minimum number of digits must be 10.
# Eg.
# 1231231234  OK
# 5551234  NOT OK
# 123-123-1234  NOT OK
# (123) 123 -1234  NOT OK
sub Phone { return shift->phone }

# Email
# Must pass RFC 822 for valid email. Currently use Regular Expression for validation:
# ^([a-zA-Z0-9_\-\.]+)@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.)|(([a-zA-Z0-9\-]+\.)+))([a-zA-Z]{2,4}|[0-9]{1,3})(\]?)$
sub Email { return shift->email }

# DOB
# Date of birth of the customer. Max age is set to 100 years. Minimum age requirement is 18 years.
# Format should be passed as MM/DD/YYYY. Default is 01/01/1900 if not passed.
# (format on get is expected to be yyyy-mm-dd.  This is returned by DateTime->ymd).
sub DOB { return shift->date_of_birth }

# Gender
# Gender of the customer:
# M=Male
# F=Female
# U=Unknown (default)
sub Gender { return uc shift->gender }

# Profile
# The profile is a numeric value specifying the "level" of the Customer on DoughFlow.
# Higher profile settings will usually permit the customer to access higher deposit limits,
# higher velocity limits and possibly new processing options.
#
# The Profile values and their mapping to our system are:
# Code - DF name          => Meaning on BOM
#    0 - Blocked          => disabled account
#    1 - Newbie (default) => newly registered user
#    2 - Bronze           => Age verified
#    3 - Silver           => Identity authenticated
#    4 - Gold             => Been with us for more than 6 months
sub Profile {
    my $self = shift;

    return 0 if $self->status->disabled;
    if ($self->status->age_verification || $self->has_valid_documents) {
        if ($self->fully_authenticated) {
            if ($self->_days_since_joined > 180) {
                return 4;
            }
            return 3;
        }
        return 2;
    }
    return 1;
}

#The number of days since the user created the account
sub _days_since_joined { return Date::Utility->new->days_between(Date::Utility->new(shift->date_joined)) }

# Password
# The password must conform to specifications set by the gaming system. Can set to ‘n/a if not used or set to an empty string. Integrations to some gaming systems may require the value and enforce rules over and above DoughFlow standards.
sub Password { return 'DO NOT USE' }

=head1 doughflow_currency

If there is one currency that the client should use with
Doughflow, this method will find and return it.

If there is any ambiguity regarding which currency the
client should use, this will return false.

=cut

sub doughflow_currency {
    my $self = shift;

    return if ($self->is_first_deposit_pending);
    return $self->currency;
}

1;
