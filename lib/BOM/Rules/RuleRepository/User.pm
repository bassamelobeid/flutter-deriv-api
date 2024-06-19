package BOM::Rules::RuleRepository::User;

=head1 NAME

BOM::Rules::RuleRepositry::User

=head1 DESCRIPTION

Contains rules pertaining the context user.

=cut

use strict;
use warnings;

use List::Util qw(any);

use BOM::Platform::Context qw(localize);
use BOM::Rules::Registry   qw(rule);

rule 'user.has_no_real_clients_without_currency' => {
    description => "Succeeds if currency of all enabled real accounts of the context landing company are set",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        my $siblings = $client->real_account_siblings_information(
            exclude_disabled_no_currency => 1,
            landing_company              => $context->landing_company($args),
            include_self                 => 1
        );

        if (my ($loginid_no_curr) = grep { not $siblings->{$_}->{currency} } keys %$siblings) {
            $self->fail(
                'SetExistingAccountCurrency',
                params      => $loginid_no_curr,
                description => "Currency for $loginid_no_curr needs to be set"
            );
        }

        return 1;
    },
};

rule 'user.email_is_verified' => {
    description => "Checks if email address is verified",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        $self->fail('email unverified', description => 'Email address is not verified for user')
            unless $client->user->email_verified;

        return 1;
    },
};

1;
