package BOM::Rules::RuleRepository::Wallet;

=head1 NAME

BOM::Rules::RuleRepositry::Wallet

=head1 DESCRIPTION

Contains rules pertaining the context wallet.

=cut

use strict;
use warnings;

use BOM::Rules::Registry   qw(rule);
use BOM::Platform::Context qw(request);

rule 'wallet.client_type_is_not_binary' => {
    description => "Succeeds if client account type is not legacy",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client       = $context->client({loginid => $args->{loginid}});
        my $account_type = $client->get_account_type->name;

        $self->fail('ClientAccountTypeIsBinary') if $account_type eq 'binary';
        return 1;
    },

};

1;
