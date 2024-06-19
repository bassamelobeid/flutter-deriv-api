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

rule 'wallet.no_duplicate_trading_account' => {
    description => "Succeeds if account type is not legacy",
    code        => sub {
        my ($self, $context, $args) = @_;

        return 1 unless ($args->{account_type} // '') eq 'standard';
        my $wallet_loginid = $args->{wallet_loginid} || return 1;
        my $client         = $context->client($args);
        my @siblings       = $context->user->clients(
            wallet_loginid  => $wallet_loginid,
            include_virtual => $client->is_virtual
        );
        return 1 unless @siblings;

        $self->fail('DuplicateTradingAccount');
    },
};

1;
