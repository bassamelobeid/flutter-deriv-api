package BOM::Rules::Engine;

=head1 NAME

BOM::Rules::Engine

=head1 SYNOPSIS

    use BOM::Rules::Engine;
    my $rule_engine = BOM::Rules::Engine->new(loginid => 'CR1234', landing_company => 'svg');

    try {
        $rule_engine->verify_action('new_account', {first_name => 'Sir John', last_name => 'Falstaff'});
    catch ($error) {
        ...
    }


=head1 DESCRIPTION

The rule engine, mainly responsible for verifying B<actions> with pre-configured B<rules>, against the current B<context>.

=cut

use strict;
use warnings;

use YAML::XS;
use Moo;

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
use BOM::Rules::RuleRepository::SelfExclusion;
use BOM::Rules::Registry qw(get_action);
use BOM::Rules::Context;

# load actions from .yml files
BOM::Rules::Registry::register_actions();

=head2 context

A read-only attribute that returns the B<context> created by rule engine's constructor.

Returns a L<BOM::Rules::Context> object

=cut

has context => (is => 'ro');

=head2 BUILDARGS

This method is implemented to override the default constructor by preprocessing context variables.

=cut

around BUILDARGS => sub {
    my ($orig, $class, %context) = @_;

    $context{client}          = BOM::User::Client->new({loginid => $context{loginid}}) if $context{loginid} && !$context{client};
    $context{loginid}         = $context{client}->loginid                              if $context{client}  && !$context{loginid};
    $context{landing_company} = $context{client}->landing_company->short               if $context{client}  && !$context{landing_company};
    $context{residence}       = $context{client}->residence                            if $context{client}  && !$context{residence};

    return $class->$orig(context => BOM::Rules::Context->new(%context));
};

=head2 verify_action

Verifies an B<action> by checking the configured B<rules> against current B<context>. Takes following list of arguments:

=over 4

=item C<action_name> the name of action to be verified

=item C<args> arguments of the action

=back

Returns true on success and dies if any contained rule is violated.

=cut

sub verify_action {
    my ($self, $action_name, $args) = @_;

    die "Action name is required" unless $action_name;

    my $action = BOM::Rules::Registry::get_action($action_name);
    die "Unknown action '$action_name' cannot be verified" unless $action;

    return $action->verify($self->context, $args // {});
}

=head2 apply_rules

Applies any number of B<rules> independently from any action. It takes following list of arguments:

=over 4

=item C<rules> an array-ref containing the list of rules to be applied

=item C<args> action argumennts for rules

=back

Returns true on success and dies if any rule is violated.

=cut

sub apply_rules {
    my ($self, $rules, $args) = @_;

    $rules = [$rules] unless ref $rules;

    for my $rule_name (@$rules) {
        my $rule = BOM::Rules::Registry::get_rule($rule_name);

        die "Unknown rule '$rule_name' cannot be applied" unless $rule;

        $rule->apply($self->context, $args // {});
        # TODO: in some contexts we will need to return all failures rather than the first one.
        # In that case the output should be restructured like:
        # failures => ['residence.market_type_is_available', 'residence.not_restricted']
    }

    return 1;
}

1;
