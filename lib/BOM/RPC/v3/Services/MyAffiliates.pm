package BOM::RPC::v3::Services::MyAffiliates;

=head1 NAME

BOM::RPC::v3::Services::MyAffiliates - helpers for MyAffiliates

=head1 DESCRIPTION

This module contains the helpers for dealing with MyAfiliate API service.

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

Common function used by both `affiliate_add_person` and `affiliate_add_company` functions

=over 4

=item * C<email> - C<Str> The email that entered in previous step of registration

=item * C<args> - C<Hash ref> Hash ref consists of : password, first_name, last_name, term and conditions

=item * C<extra_fields> - C<Hash ref> Hash ref consists of extra fields ( for business account) like company name and number

=back

=cut

sub affiliate_add_general {
    my ($email, $args, $extra_fields) = @_;

    $extra_fields //= {};
    my $fields = {
        PARAM_email         => $email,
        PARAM_username      => $email,
        PARAM_first_name    => $args->{first_name},
        PARAM_last_name     => $args->{last_name},
        PARAM_date_of_birth => $args->{date_of_birth},
        PARAM_individual    => 1,
        PARAM_whatsapp      => $args->{phone},
        PARAM_phone_number  => $args->{phone},
        PARAM_country       => $args->{country},
        PARAM_city          => $args->{address_city},
        PARAM_state         => $args->{address_state},
        PARAM_postcode      => $args->{address_postcode},
        PARAM_website       => $args->{website_url},
        PARAM_agreement     => $args->{tnc_accepted},
        %$extra_fields
    };

    try {
        my $aff_id = $myaffiliate->register_affiliate(%$fields)->get;
        return {
            code => "SuccessRegister",
        };
    } catch ($e) {
        return {
            code              => "MYAFFRuntimeError",
            message_to_client => $e
        };
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

=head2 affiliate_add_company

Register the company affiliate via MyAffiliate API with corresponding inputs

=over 4

=item * C<email> - C<Str> The email that entered in previous step of registration

=item * C<args> - C<Hash ref> Hash ref consists of : password, first_name, last_name, term and conditions

=back

=cut

sub affiliate_add_company {
    my ($email, $args) = @_;

    my $extra_fields = {
        BusinessType              => "Company",
        Company                   => $args->{company_name},
        CompanyRegistrationNumber => $args->{company_register_number}};
    return affiliate_add_general($email, $args, $extra_fields);
}

END {
    $loop->remove($myaffiliate);
}

1;
