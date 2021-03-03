package BOM::Rules::RuleRepository::Client;

=head1 NAME

BOM::Rules::RuleRepositry::Client

=head1 DESCRIPTION

Contains rules pertaining the context client.

=cut

use strict;
use warnings;

use LandingCompany::Registry;

use BOM::Platform::Context qw(localize);
use BOM::Rules::Registry qw(rule);

rule 'client.address_postcode_mandatory' => {
    description => "Checks if there's a postalcode in action args or in the context client",
    code        => sub {
        my ($self, $context, $args) = @_;

        die +{code => 'PostcodeRequired'} unless $args->{address_postcode} // $context->client->address_postcode;

        return 1;
    },
};

rule 'client.no_pobox_in_address' => {
    description => "Succeeds if there's no pobox in address args",
    code        => sub {
        my ($self, undef, $args) = @_;

        die +{code => 'PoBoxInAddress'}
            if (($args->{address_line_1} || '') =~ /p[\.\s]?o[\.\s]+box/i
            or ($args->{address_line_2} || '') =~ /p[\.\s]?o[\.\s]+box/i);

        return 1;
    },
};

rule 'client.check_duplicate_account' => {
    description => "Performs a duplocate check on the context client and the action args",
    code        => sub {
        my ($self, $context, $args) = @_;

        die +{code => 'DuplicateAccount'} if $context->client->check_duplicate_account($args);

        return 1;
    },
};
