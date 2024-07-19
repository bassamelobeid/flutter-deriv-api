package BOM::RPC::v3::Services::MyAffiliates;

=head1 NAME
BOM::RPC::v3::Services::MyAffiliates - helpers for MyAffiliates
=head1 DESCRIPTION
This module contains the helpers for dealing with MyAfiliate API service.
BOM::RPC::v3::Services::MyAffiliates - helpers for MyAffiliates
=cut

use strict;
use warnings;
use BOM::Config;
use BOM::MyAffiliates::WebService;
use Syntax::Keyword::Try;
use Log::Any qw( $log );
use IO::Async::Loop;
use BOM::RPC::v3::Utility;
use BOM::RPC::Transport::HTTP;
use JSON::XS;
use XML::LibXML;
# constants for type of account MyAffiliates
use constant INDIVIDUAL_ACC_TYPE => 1;
use constant BUSINESS_ACC_TYPE   => 2;
my $loop;
my $myaffiliate;
my $myaffiliate_config;

BEGIN {
    $myaffiliate_config = BOM::Config::third_party()->{myaffiliates};
    $myaffiliate        = BOM::MyAffiliates::WebService->new(
        base_uri => $myaffiliate_config->{host},
        user     => $myaffiliate_config->{user},
        pass     => $myaffiliate_config->{pass});
    $loop = IO::Async::Loop->new;
    $loop->add($myaffiliate);
}

=head2 affiliate_add_general
Common function used by `affiliate_add_person` function
=over 4
=item * C<email> - C<Str> The email that entered in previous step of registration
=item * C<args> - C<Hash ref> Hash ref consists of : password, first_name, last_name, term and conditions
=item * C<extra_fields> - C<Hash ref> Hash ref consists of extra fields ( for business account) like company name and number
=back
=cut

sub affiliate_add_general {
    my ($email, $args) = @_;
    my $fields = {
        PARAM_email          => $email,
        PARAM_username       => $args->{user_name},
        PARAM_first_name     => $args->{first_name},
        PARAM_last_name      => $args->{last_name},
        PARAM_date_of_birth  => $args->{date_of_birth},
        PARAM_individual     => $args->{type_of_account} eq INDIVIDUAL_ACC_TYPE ? "individual" : "non-individual",
        PARAM_whatsapp       => $args->{whatsapp_number},
        PARAM_phone_number   => $args->{phone},
        PARAM_country        => $args->{country},
        PARAM_city           => $args->{address_city},
        PARAM_state          => $args->{address_state},
        PARAM_postcode       => $args->{address_postcode} // '',
        PARAM_website        => $args->{website_url},
        PARAM_agreement      => $args->{tnc_accepted},
        PARAM_ph_countrycode => $args->{phone_code},
        PARAM_plans          => $args->{commission_plan},
        PARAM_wa_countrycode => $args->{whatsapp_number_phoneCode},
        PARAM_address        => $args->{address_street},
        PARAM_age            => $args->{over_18_declaration} eq 1 ? "over_eighteen" : "not_eighteen"
    };

    # Removing special characters like , ;''"":&
    # Leaving the non-latin character
    # Example:
    # London, Great Britain => London
    # île de Man stays île de Man

    $fields->{PARAM_state} =~ s/[^\p{L}\p{N}\s]//g;

    if ($args->{type_of_account} eq BUSINESS_ACC_TYPE) {
        if (!(defined($args->{company_name}) && defined($args->{company_registration_number}))) {
            return {
                code              => "MYAFFRuntimeError",
                message_to_client => "Company name and company registration number are required for business account"
            };
        }
        $fields->{PARAM_business}           = $args->{company_name};
        $fields->{PARAM_business_regnumber} = $args->{company_registration_number};
    }
    if (defined($args->{password})) {
        $fields->{PARAM_password} = $args->{password};
    }
    # Create an XML::LibXML object
    my $parser = XML::LibXML->new();
    try {
        my $aff_id = $myaffiliate->register_affiliate(%$fields)->get;
        my $doc    = $parser->load_xml(string => $aff_id);
        my $userid = $doc->findvalue('//USERID') // '';
        return {
            code   => "SuccessRegister",
            userid => $userid
        };
    } catch ($e) {
        # Check if the exception variable $e is an object or not
        if (ref($e)) {
            # Parse the XML string
            my $xml_doc = $parser->parse_string($e->{error_message});
            # Access the root element
            my $root = $xml_doc->documentElement();
            # Access the ERROR element
            my $error_element = $root->findnodes('/ACCOUNT/INIT/ERROR')->[0];
            # Access the text content of the MSG element
            my $msg_content = $error_element->findvalue('./MSG');
            return {
                code              => "MYAFFRuntimeError",
                message_to_client => $msg_content
            };
        } else {
            return {
                code              => "MYAFFRuntimeError",
                message_to_client => "Error in response structure"
            };
        }
    }
}

=head2 affiliate_add_person
Register the individual affiliate via MyAffiliate API with corresponding inputs
=over 4
=item * C<email> - C<Str> The email that entered in previous step of registration
=item * C<args> - C<Hash ref> Hash ref consists of : password, first_name, last_name, term and conditions
=back
=cut

sub affiliate_add_person {
    my ($email, $args) = @_;
    return affiliate_add_general($email, $args);
}

END {
    $loop->remove($myaffiliate);
}
1;
