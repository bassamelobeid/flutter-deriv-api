package BOM::Rules::Registry;

# TODO: this module should be turned into a class

=head1 NAME

BOM::Rules::Registry

=head1 DESCRIPTION

This module manages rule engine's rule and action sets, with B<rule> and B<action> auto-load and lookup functionalities.

=cut

use strict;
use warnings;

use YAML::XS;
use Carp;

use BOM::Rules::Registry::Action;
use BOM::Rules::Registry::Rule;
use BOM::Rules::Registry::Rule::Conditional;
use BOM::Rules::Context;

use base qw(Exporter);
our @EXPORT_OK = qw(get_action get_rule rule register_action);

=head2 CONFIG_PATH

The path of the local directory in which the config files of L<BOM::Rules> can be found.

=cut

use constant CONFIG_PATH => "/home/git/regentmarkets/bom-rules/config/";

our %rule_registry;
our %action_registry;

=head2 get_action

Looks up registered/configured actions by name.

Returns a L<BOM::Rules::Registry::Action> object.

=cut

sub get_action {
    my $name = shift;

    return $action_registry{$name};
}

=head2 get_rule

Looks up configured rules by name.

Returns a L<BOM::Rules::Registry::Rule> object.

=cut

sub get_rule {
    my $name = shift;

    die 'Rule name cannot be empty' unless $name;

    return $rule_registry{$name};
}

=head2 rule

As the main rule declaration method, it creates and registers a L<BOM::Rules::Rule> by processing the input arguments.
It takes following named arguments:

=over 4

=item C<name> Rule's name.

=item C<rule_settings> Rule's settings as a hash-ref with following content:

=over 4

=item C<code> A call-back function to be executed on rule's application.

=item C<description> A short description of the rule.

=back

=back

Returns a L<BOM::Rules::Registry::Rule> object.

=cut

sub rule {
    my ($name, $rule_settings) = @_;

    croak 'Rule name is required but missing' unless $name;
    croak "Rule '$name' is already registered" if $rule_registry{$name};

    croak "No code associated with rule '$name'" unless $rule_settings->{code} && ref($rule_settings->{code}) eq 'CODE';

    $rule_settings->{description} //= $name;

    $rule_registry{$name} = BOM::Rules::Registry::Rule->new(%$rule_settings, name => $name);

    return $rule_registry{$name};
}

=head2 register_actions

Loads and registered B<actions> from the default configurtion path.

=cut

sub register_actions {
    # it should be executed only once
    if (%action_registry) {
        warn 'Rule registery is already loaded';
        return \%action_registry;
    }

    for my $file (_get_action_files()) {
        next unless $file =~ /\.yml$/;
        my $config   = YAML::XS::LoadFile(CONFIG_PATH . "/actions/$file");
        my $category = $file =~ qr/(.*)\.yml/;

        for my $action_name (keys %$config) {
            die 'Action name is required but missing' unless $action_name;

            my $action_config = $config->{$action_name};
            die "Rule set of action '$action_name' is not a hash" unless ref $action_config eq 'HASH';

            die "Rule '$action_name' doesn't have any 'ruleset'" unless $action_config->{ruleset};

            _register_action(
                $action_name,
                category    => $category,
                description => $action_config->{description},
                rule_set    => $action_config->{ruleset},
            );
        }
    }

    return \%action_registry;
}

=head2 _get_action_files

Returns a list of actions files from the /actions folder.

=cut

sub _get_action_files {
    opendir my $dir, CONFIG_PATH . '/actions/';
    my @files = readdir $dir;
    closedir $dir;
    return @files;
}

=head2 _register_action

It creates and registers a L<BOM::Rules::Action> object by processing the input arguments.
It takes following named arguments:

=over 4

=item C<name> Actions's name

=item C<description> A short description of the action.

=item C<rule_set> Rules configured as a hash-ref or array-ref. It will be processed to extract the action's C<rule-set>.

=back

Returns a L<BOM::Rules::Registry::Action> object.

=cut

sub _register_action {
    my ($name, %args) = @_;

    die "Action $name is already declared" if $action_registry{$name};

    my $rule_set = delete $args{rule_set};

    $args{name} = $name;
    $args{description} //= $name;

    # convert rule names to rule objects
    $args{rule_set} = _process_ruleset($name, $rule_set);

    $action_registry{$name} = BOM::Rules::Registry::Action->new(%args);

    return $action_registry{$name};
}

=head2 _process_ruleset

Converts action rule-set from a collection of rule names into equivalent collection of rule objects, by taking these params:

=over 4

=item C<action_name> Action name

=item C<rule_set_config> A rule-set configured by rule names (for example in action conig files)

=back

=cut

sub _process_ruleset {
    my ($action_name, $rule_set_config) = @_;

    unless (ref $rule_set_config) {
        my $rule = get_rule($rule_set_config);
        die "Rule '$rule_set_config' used in action '$action_name' was not found" unless $rule;
        return [$rule];
    }

    return [map { _process_ruleset($action_name, $_)->@* } @$rule_set_config] if ref $rule_set_config eq 'ARRAY';

    my @result;
    # The rule is a hash-ref at this point, interpreted as a conditional rule.
    for my $condition_type (keys %$rule_set_config) {
        die "Invalid condition type '$condition_type' in action '$action_name': only 'context' and 'args' are acceptable"
            unless $condition_type =~ qr /^context|args$/;

        # a conditional rule looks like a switch-case control structure in progrmming.
        for my $switch_key (keys $rule_set_config->{$condition_type}->%*) {
            # For example, in the following config, we will have $condition_type=context and $switch_key=landing_company
            #  context:
            #   landing_company:
            #     mlt:
            #       - rule1
            #      mf:
            #       - rule2

            die "Invalid context key '$switch_key' used for a conditional rule in action '$action_name'"
                if $condition_type eq 'context' && !"BOM::Rules::Context"->can($switch_key);

            my $config = $rule_set_config->{$condition_type}->{$switch_key};
            die "Conditional structure of rule '$condition_type->$switch_key' in action '$action_name' is not a hash" unless ref $config eq 'HASH';

            my @cases = keys $config->%*;
            # in the example above: @cases = (mlt, mf)

            my %rules_per_case =
                map { $_ => _process_ruleset($action_name, $config->{$_}) } @cases;
            # in the example above, we will get: %rules_per_case = (mlt => [rule1], mf => [rule2])

            push @result,
                BOM::Rules::Registry::Rule::Conditional->new(
                "${condition_type}_key" => $switch_key,
                rules_per_value         => \%rules_per_case
                );
        }
    }

    return \@result;
}

1;
