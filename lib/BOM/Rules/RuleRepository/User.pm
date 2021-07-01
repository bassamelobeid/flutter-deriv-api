package BOM::Rules::RuleRepository::User;

=head1 NAME

BOM::Rules::RuleRepositry::User

=head1 DESCRIPTION

Contains rules pertaining the context user.

=cut

use strict;
use warnings;

use LandingCompany::Registry;
use List::Util qw(any);

use BOM::Platform::Context qw(localize);
use BOM::Rules::Registry qw(rule);

rule 'user.has_no_real_clients_without_currency' => {
    description => "Succeeds if currency of all ennabled real accounts of the context landing company are set",
    code        => sub {
        my ($self, $context) = @_;

        die 'Client is missing' unless $context->client;

        my $siblings = $context->client->real_account_siblings_information(
            exclude_disabled_no_currency => 1,
            landing_company              => $context->landing_company,
            include_self                 => 1
        );

        if (my ($loginid_no_curr) = grep { not $siblings->{$_}->{currency} } keys %$siblings) {
            die +{
                error_code => 'SetExistingAccountCurrency',
                params     => $loginid_no_curr
            };
        }

        return 1;
    },
};

rule 'user.email_is_verified' => {
    description => "Checks if email address is verified",
    code        => sub {
        my ($self, $context, $args) = @_;

        die +{
            error_code => 'email unverified',
            }
            unless $context->client->user->email_verified;

        return 1;
    },
};

1;
