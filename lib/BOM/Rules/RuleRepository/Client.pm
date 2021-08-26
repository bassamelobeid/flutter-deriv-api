package BOM::Rules::RuleRepository::Client;

=head1 NAME

BOM::Rules::RuleRepositry::Client

=head1 DESCRIPTION

Contains rules pertaining the context client.

=cut

use strict;
use warnings;

use LandingCompany::Registry;

use BOM::Rules::Registry qw(rule);
use BOM::Config::Runtime;
use BOM::Config::CurrencyConfig;

rule 'client.check_duplicate_account' => {
    description => "Performs a duplicate check on the target client and the action args",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('DuplicateAccount') if $context->client($args)->check_duplicate_account($args);

        return 1;
    },
};

rule 'client.has_currency_set' => {
    description => 'Checks whether the target client has its currency set',
    code        => sub {
        my ($self, $context, $args) = @_;

        my $account = $context->client($args)->account;
        my $currency_code;

        $currency_code = $account->currency_code if $account;

        $self->fail('SetExistingAccountCurrency') unless $currency_code;

        return 1;
    },
};

rule 'client.residence_is_not_empty' => {
    description => "fails if the target client's residence is not set yet.",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('NoResidence') unless $context->client($args)->residence;

        return 1;
    },
};

# TODO: it's copied from bom-platform unchanged; but it should be removed in favor of client.immutable_fields
rule 'client.signup_immitable_fields_not_changed' => {
    description => "fails if any of the values of signup immutable fields are changed in the args.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client = $context->get_real_sibling($args);

        return 1 if $client->is_virtual;

        my @changed;
        for my $field (qw /citizen place_of_birth residence/) {
            next unless $client->$field and exists $args->{$field};

            push(@changed, $field) if $client->$field ne ($args->{$field} // '');
        }

        $self->fail('CannotChangeAccountDetails', details => {changed => [@changed]}) if @changed;

        return 1;
    },
};

rule 'client.is_not_virtual' => {
    description => 'It dies with a permission error if the target client is virtual; succeeds otherwise.',
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('PermissionDenied') if $context->client($args)->is_virtual;

        return 1;
    }
};

rule 'client.forbidden_postcodes' => {
    description => "Checks if postalcode is not allowed",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client                     = $context->client($args);
        my $forbidden_postcode_pattern = $context->get_country($client->residence)->{forbidden_postcode_pattern};
        my $postcode                   = $args->{address_postcode} // $client->address_postcode;

        $self->fail('ForbiddenPostcode') if (defined $forbidden_postcode_pattern && $postcode =~ /$forbidden_postcode_pattern/i);

        return 1;
    },
};

1;
