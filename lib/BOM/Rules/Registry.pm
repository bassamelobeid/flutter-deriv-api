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
use Syntax::Keyword::Try;

use BOM::Rules::Registry::Action;
use BOM::Rules::Registry::Rule;
use BOM::Rules::Registry::Rule::Conditional;
use BOM::Rules::Registry::Rule::Group;
use BOM::Rules::Context;

use base qw(Exporter);
our @EXPORT_OK = qw(get_action get_rule rule register_action);

=head2 CONFIG_PATH

The path of the local directory in which the config files of L<BOM::Rules> can be found.

=cut

use constant CONFIG_PATH => "/home/git/regentmarkets/bom-rules/config/";

our %rule_registry;
our %group_registry;
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

=head2 _register_rule_groups

Loads and registered B<rule groups> from the default configurtion path.

=cut

sub _register_rule_groups {
    # it should be executed only once
    %group_registry = ();

    for my $file (_get_config_files('rule_groups')) {

        my $config;
        try {
            $config = YAML::XS::LoadFile(CONFIG_PATH . "rule_groups/$file");
        } catch ($e) {
            die "Error processing file rule_groups/$file: $e";
        };

        die "Invalid config file structure in $file" unless ref $config eq 'HASH';

        for my $group_name (keys %$config) {
            my $config = $config->{$group_name};
            die "Config of rule-group '$group_name' doesn't look like a hash - file: $file" unless ref $config eq 'HASH';

            die "Rule-group '$group_name' doesn't have any 'ruleset' -  file: $file" unless $config->{ruleset};

            my $ruleset = _process_ruleset("ruleset $file -> $group_name", $config->{ruleset} // []);

            $group_registry{$group_name} = {
                description        => $config->{description} // $group_name,
                required_arguments => $config->{required_arguments} //= [],
                ruleset            => $ruleset,
            };
        }
    }
    return \%action_registry;
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

    _register_rule_groups();

    for my $file (_get_config_files('actions')) {

        my $config;
        try {
            $config = YAML::XS::LoadFile(CONFIG_PATH . "actions/$file");
        } catch ($e) {
            die "Error processing file actions/$file: $e";
        };

        $file =~ qr/(.*)\.yml/;
        my $category = $1;

        for my $action_name (keys %$config) {
            die "Action name is required but missing - file: $file" unless $action_name;

            my $action_config = $config->{$action_name};
            die "Configuration of action '$action_name' doesn't look like a hash - file: $file" unless ref $action_config eq 'HASH';

            die "Action '$action_name' doesn't have any 'ruleset' - file: $file" unless $action_config->{ruleset};

            _register_action(
                $action_name,
                category    => $category,
                description => $action_config->{description},
                ruleset     => $action_config->{ruleset},
            );
        }
    }

    return \%action_registry;
}

=head2 _get_config_files

Returns a list of configuration files from the specified type. Gets a single argument:

=over 4

=item C<type> Configuration type (or subdirectory name); two types are supported as of now: C<action> and C<rule_group>.

=back

=cut

sub _get_config_files {
    my ($type) = @_;

    die 'Empty config type' unless $type;

    opendir(my $dir, CONFIG_PATH . "$type/") || return ();

    my @files = readdir $dir;
    closedir $dir;

    @files = sort(grep { /\.yml$/ } @files);

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

    my $ruleset = delete $args{ruleset};

    $args{name} = $name;
    $args{description} //= $name;

    # convert rule names to rule objects
    $args{ruleset} = _process_ruleset($name, $ruleset);

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
        die "Rule '$rule_set_config' used in '$action_name' was not found" unless $rule;
        return [$rule];
    }

    return [map { _process_ruleset($action_name, $_)->@* } @$rule_set_config] if ref $rule_set_config eq 'ARRAY';

    my @result;

    # a complex rule (represented by a hash-ref) is identified: conditional rule or a group.
    my $composite_rule = $rule_set_config;
    my $type           = $composite_rule->{type} // '';

    if ($type eq 'conditional') {
        push @result, _load_conditional_rule($action_name, $composite_rule);
    } elsif ($type eq 'group') {
        push @result, _load_rule_group($action_name, $composite_rule);
    } else {
        die "Unknown composite rule type '$type' found in '$action_name'; only 'conditional' and 'group' allowed";
    }

    return \@result;
}

=head2 _load_rule_group

Creates an object of class L<BOM::Rules::Registry::Rule::Group> from a rule-group section in an action configuration.
The arguments are:

=over 4

=item C<action_name> Action name

=item C<config> A rule-group declaraion in an action .yml config file.

=back

=cut

sub _load_rule_group {
    my ($action_name, $config) = @_;

    my $arguments;
    my $ruleset;
    my $name;
    my $description;

    if ($config->{rule_group}) {
        # rules are either copied from a registered rule group
        my $group_config = $group_registry{$config->{rule_group}};
        die "Invalid group name $config->{rule_group} found in $action_name" unless $group_config;

        die "Ruleset incorrectly declared for a known rule-group ($config->{rule_group}) in $action_name" if $config->{ruleset};

        $name        = $config->{name}        // $config->{rule_group};
        $description = $config->{description} // $group_config->{description};
        $arguments   = $group_config->{required_arguments};
        $ruleset     = $group_config->{ruleset};
    } else {
        # or from an explicit rule listing
        $name        = $config->{name} // 'anonymous';
        $description = $config->{description};
        $description //= 'Unnamed group in action configuration' if $name eq 'anonymous';
        $ruleset = _process_ruleset($action_name, $config->{ruleset} // []);
    }

    return BOM::Rules::Registry::Rule::Group->new(
        name               => $name,
        description        => $description                // $name,
        required_arguments => $arguments                  // [],
        ruleset            => $ruleset                    // [],
        argument_mapping   => $config->{argument_mapping} // {},
        tag                => $config->{tag},
    );
}

=head2 _load_conditional_rule

Creates an object of class L<BOM::Rules::Registry::Rule::Connditional> from a rule-group section in an action configuration.
The arguments are:

=over 4

=item C<action_name> Action name

=item C<config> A conditional rule's declaraion in a config file.

=back

=cut

sub _load_conditional_rule {
    my ($action_name, $rule_config) = @_;

    # a conditional rule looks like a switch-case control structure in progrmming.
    my $switch_key = $rule_config->{on};
    die "Conditional rule without target arg found in $action_name ('on' hash key not found)." unless $switch_key;
    die "Conditional rule rules_per_value found in $action_name"                               unless $rule_config->{rules_per_value};

    $rule_config->{rules_per_value}->{default} //= [];
    my @cases = keys $rule_config->{rules_per_value}->%*;

    # For example, in the following config, we will have $switch_key=landing_company and $cases=(mlt, mf)
    #   type: conditional
    #   on:   landing_company
    #   rules_per_value:
    #     mlt:
    #       - rule1
    #      mf:
    #       - rule2

    my %rules_per_case =
        map { $_ => _process_ruleset($action_name, $rule_config->{rules_per_value}->{$_}) } @cases;
    # in the example above, we expect to get: %rules_per_case = (mlt => [rule1], mf => [rule2])

    my @result;
    push @result,
        BOM::Rules::Registry::Rule::Conditional->new(
        key             => $switch_key,
        rules_per_value => \%rules_per_case
        );

    return @result;
}

1;
