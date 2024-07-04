package BOM::MyAffiliates::DynamicWorks::SyntellicoreRequester;

use Object::Pad;

=head1 NAME

SyntellicoreRequester - A Perl class for making requests to the Syntellicore system.

=head1 DESCRIPTION

This module provides a simple interface for making requests to the Syntellicore system.

=cut

=head1 FIELDS

=head2 $version

The version of the Syntellicore system.

=cut

=head1 METHODS


=head2 new 

This method initializes the class with the configuration for the Syntellicore system.

=cut

use strict;
use warnings;
use BOM::Config;

class BOM::MyAffiliates::DynamicWorks::SyntellicoreRequester :isa(BOM::MyAffiliates::DynamicWorks::Requester) {

=head2 getConfig

This method returns the configuration for the Syntellicore system which is used by parent class's constructor.

=over 4

=item * Returns

A hash reference containing the configuration for the Syntellicore system.

=back

=cut

    method getConfig {
        my $config = BOM::Config::third_party()->{dynamic_works}->{syntellicore};

        die "Config not defined for syntellicore_crm" unless $config;

        return $config;
    }

=head2 getCountries

This method returns a list of countries.

=over 4

=item * $language (optional)

The language in which the countries should be returned. Defaults to 'en'.

=item * Returns

A hashref of countries.

=back

=cut

    method getCountries ($language = undef) {
        return $self->api_request({
            method              => 'POST',
            api                 => 'get_countries',
            content             => {language => $language // 'en'},
            do_not_authenticate => 1,
        });
    }

=head2 createUser

This method creates a new user in the Syntellicore system.

=over 4

=item * $args

A hash reference containing the following

=over 4

=item - first_name

The first name of the user.

=item - last_name

The last name of the user.

=item - email

The email address of the user.

=item - password

The password of the user.

=item - country_id

The ID of the country in which the user resides.

=item - currency

The currency of the user.

=item - is_ib

Whether the user is an IB affiliate.

=item - language (optional)

The language of the user. Defaults to 'en'.

=item - sidc

=item - company

=back

=item * Returns

A hash reference containing the response from the Syntellicore system.

=back

=cut

    method createUser ($args) {

        # Check for required arguments
        die "First name (first_name) is required" unless defined $args->{first_name};
        die "Last name (last_name) is required"   unless defined $args->{last_name};
        die "Email (email) is required"           unless defined $args->{email};
        die "Password (password) is required"     unless defined $args->{password};
        die "Country_id (country_id) is required" unless defined $args->{country_id};
        die "Currency (currency) is required"     unless defined $args->{currency};
        die "Is IB affiliate (is_ib) is required" unless defined $args->{is_ib};

        # Initialize content with required fields
        my $content = {
            fname      => $args->{first_name},
            lname      => $args->{last_name},
            email      => $args->{email},
            password   => $args->{password},
            country_id => $args->{country_id},
            currency   => $args->{currency},
            language   => $args->{language} ? $args->{language} : 'en',
            is_ib      => $args->{is_ib}};

        # List of optional parameters
        my @optional_params = qw(
            sidc company introducer suid httpref auto_responder campaign_id
            channel_id utm_source utm_medium utm_campaign utm_term utm_content utm_device
            utm_creative utm_network remote_host remote_addr remote_country lead_method
            is_lead cstt_id birth_dt tel_number tel_provider_code tel_country_code
            agreement_id_list extended_fields service_id address city zip address2 city2
            zip2 website company_country_id company_registration_number
            company_lei_code verify brand_id
        );

        # Add optional parameters to content if they exist
        for my $param (@optional_params) {
            $content->{$param} = $args->{$param} if exists $args->{$param};
        }

        return $self->api_request({
            method              => 'POST',
            api                 => 'create_user',
            content             => $content,
            do_not_authenticate => 1,
        });
    }

}

1;
