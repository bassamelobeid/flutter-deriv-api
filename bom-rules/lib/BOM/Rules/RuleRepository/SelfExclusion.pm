package BOM::Rules::RuleRepository::SelfExclusion;

=head1 NAME

BOM::Rules::RuleRepositry::SelfExclusion

=head1 DESCRIPTION

Contains rules governing self-exclusions.

=cut

use strict;
use warnings;
use Date::Utility;
use BOM::Rules::Registry qw(rule);

rule 'self_exclusion.not_self_excluded' => {
    description => "Fails if client is already self-excuded until a certain time.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        die 'Client is missing' unless $client;

        my $excluded_until = $client->get_self_exclusion_until_date;
        $self->fail(
            'SelfExclusion',
            params  => [$excluded_until],
            details => {excluded_until => $excluded_until}) if $excluded_until;

        return 1;
    },
};

rule 'self_exclusion.sibling_account_not_excluded' => {
    description => "Fails if sibiling account is self-excuded until a certain time.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);
        die 'Client is missing' unless $client;
        my $siblings = $context->client_siblings($args);
        push @$siblings, $client;
        for my $sibling (@$siblings) {
            next unless $sibling->self_exclusion;
            my $excluded_until = $sibling->self_exclusion->timeout_until;
            next unless $excluded_until and $excluded_until > time;
            $excluded_until = Date::Utility->new($excluded_until)->date();
            $self->fail(
                'SelfExclusion',
                params  => [$excluded_until],
                details => {excluded_until => $excluded_until});
        }
        return 1;
    },
};

rule 'self_exclusion.deposit_limits_allowed' => {
    description => "Fails if trying to set deposit limits, when it's not allowed in the context landing company.",
    code        => sub {
        my ($self, $context, $args) = @_;

        return 1 if $context->landing_company_legacy($args)->deposit_limit_enabled;

        for my $max_deposit_field (qw/max_deposit max_7day_deposit max_30day_deposit/) {
            $self->fail('SetSelfExclusionError', details => $max_deposit_field)
                if $args->{$max_deposit_field};
        }
        return 1;
    },
};

1;
