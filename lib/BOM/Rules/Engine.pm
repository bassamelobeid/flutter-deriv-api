package BOM::Rules::Engine;

=head1 NAME

BOM::Rules::Engine

=head1 SYNOPSIS

    use BOM::Rules::Engine;
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    try {
        $rule_engine->verify_action('set_settings', loginid => $client->loginid, first_name => 'Sir John', last_name => 'Falstaff');
    catch ($error) {
        # error handling
    }

    # This can be rewritten equalantly without dying on failure:

    my $rule_engine = BOM::Rules::Engine->new(client => $client, stop_on_failure => 0);
    my $result = $rule_engine->verify_action('set_settings', loginid => $client->loginid, first_name => 'Sir John', last_name => 'Falstaff');
    if ($result->has_error) {
        # error handling       
    }


=head1 DESCRIPTION

The rule engine, mainly responsible for verifying B<actions> with pre-configured B<rules>, against the current B<context>.

=cut

use strict;
use warnings;

use YAML::XS;
use Moo;
use Scalar::Util qw(blessed);
use List::Util   qw(all);

use BOM::User::Client;
use BOM::Rules::RuleRepository::Basic;
use BOM::Rules::RuleRepository::User;
use BOM::Rules::RuleRepository::Client;
use BOM::Rules::RuleRepository::LandingCompany;
use BOM::Rules::RuleRepository::Residence;
use BOM::Rules::RuleRepository::Onfido;
use BOM::Rules::RuleRepository::TradingAccount;
use BOM::Rules::RuleRepository::Currency;
use BOM::Rules::RuleRepository::Profile;
use BOM::Rules::RuleRepository::Transfers;
use BOM::Rules::RuleRepository::FinancialAssessment;
use BOM::Rules::RuleRepository::SelfExclusion;
use BOM::Rules::RuleRepository::IdentityVerification;
use BOM::Rules::RuleRepository::Paymentagent;
use BOM::Rules::RuleRepository::Cashier;
use BOM::Rules::RuleRepository::Payment;
use BOM::Rules::RuleRepository::P2P;
use BOM::Rules::RuleRepository::MT5;
use BOM::Rules::RuleRepository::Wallet;

use BOM::Rules::Registry qw(get_action);
use BOM::Rules::Context;

# load actions from .yml files
BOM::Rules::Registry::register_actions();

=head2 BUILDARGS

This method is implemented to override the default constructor by preprocessing context variables.

=cut

around BUILDARGS => sub {
    my ($orig, $class, %constructor_args) = @_;

    my $client      = $constructor_args{client} // [];
    my $client_list = ref($client) eq 'ARRAY' ? $client : [$client];
    die 'Invalid client object' unless all { blessed($_) && $_->isa('BOM::User::Client') } @$client_list;

    return $class->$orig(context => BOM::Rules::Context->new(%constructor_args, client_list => $client_list));
};

=head2 context

A read-only attribute that returns the B<context> created by rule engine's constructor.

=cut

has context => (is => 'ro');

=head2 verify_action

Verifies an B<action> by checking the configured B<rules> against current B<context>. Takes following list of arguments:

=over 4

=item C<action_name> the name of action to be verified

=item C<args> In addition to action arguments, it accepts the following special key:

=over 4

=item C<rule_engine_context> With this special argument you can override rule engine's context attributes, like I<stop_on_failure>.

=back

=back

Returns true on success and dies if any contained rule is violated.

=cut

sub verify_action {
    my ($self, $action_name, %args) = @_;

    die "Action name is required" unless $action_name;

    my $action = BOM::Rules::Registry::get_action($action_name);
    die "Unknown action '$action_name' cannot be verified" unless $action;

    my $rule_engine_context = delete($args{rule_engine_context}) // {};
    my $context             = $self->context->clone(%$rule_engine_context, action => $action_name);

    return $action->verify($context, \%args);
}

=head2 apply_rules

Applies any number of B<rules> independently from any action. It takes following list of arguments:

=over 4

=item C<rules> an array-ref containing the list of rules to be applied

=item C<args> In addition to rule arguments, it accepts the following special key:

=over 4

=item C<rule_engine_context> With this special argument you can override rule engine's context attributes, like I<stop_on_failure>.

=back

=back

Returns true on success and dies if any rule is violated.

=cut

sub apply_rules {
    my ($self, $rules, %args) = @_;

    $rules = [$rules] unless ref $rules;

    my $rule_engine_context = delete($args{rule_engine_context}) // {};
    my $context             = $self->context->clone(%$rule_engine_context);

    my $final_results = BOM::Rules::Result->new();
    for my $rule_name (@$rules) {
        my $rule = BOM::Rules::Registry::get_rule($rule_name);

        die "Unknown rule '$rule_name' cannot be applied" unless $rule;

        $final_results->merge($rule->apply($context, \%args));
    }

    return $final_results;
}

1;
