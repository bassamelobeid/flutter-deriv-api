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
use BOM::Config::Runtime;
use BOM::Config::CurrencyConfig;

rule 'client.check_duplicate_account' => {
    description => "Performs a duplicate check on the context client and the action args",
    code        => sub {
        my ($self, $context, $args) = @_;

        die +{error_code => 'DuplicateAccount'} if $context->client->check_duplicate_account($args);

        return 1;
    },
};

rule 'client.has_currency_set' => {
    description => 'Checks whether the context client has its currency set',
    code        => sub {
        my ($self, $context, $args) = @_;

        my $account = $context->client->account;
        my $currency_code;

        $currency_code = $account->currency_code if $account;

        die +{error_code => 'SetExistingAccountCurrency'} unless $currency_code;

        return 1;
    },
};

rule 'client.residence_not_changed' => {
    description => "Fails if the country of residence in the request args is different from the client's residence.",
    code        => sub {
        my ($self, $context, $args) = @_;

        die +{
            error_code => 'InvalidResidence',
        } if ($args->{residence} and $args->{residence} ne $context->client->residence);

        return 1;
    },
};

rule 'client.residence_is_not_empty' => {
    description => "Fails if the context client's residence is not set yet.",
    code        => sub {
        my ($self, $context, $args) = @_;

        die +{
            error_code => 'NoResidence',
        } unless $context->client->residence;

        return 1;
    },
};

# TODO: it's copied from bom-platform unchanged; but it should be removed in favor of client.immutable_fields
rule 'client.signup_immitable_fields_not_changed' => {
    description => "Fails if any of the values of signup immutable fields are changed in the args.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client = $context->client_switched;

        return 1 if $client->is_virtual;

        my @changed;
        for my $field (qw /citizen place_of_birth residence/) {
            next unless $client->$field and exists $args->{$field};

            push(@changed, $field) if $client->$field ne ($args->{$field} // '');
        }

        die +{
            error_code => 'CannotChangeAccountDetails',
            details    => {changed => [@changed]},
        } if @changed;

        return 1;
    },
};

rule 'client.is_not_virtual' => {
    description => 'It dies with a permission error if the context client is virtual; succeeds otherwise.',
    code        => sub {
        my ($self, $context) = @_;

        die {error_code => 'PermissionDenied'} if $context->client->is_virtual;

        return 1;
    }
};

1;
