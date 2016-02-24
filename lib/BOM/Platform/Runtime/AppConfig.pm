package BOM::Platform::Runtime::AppConfig;

=head1 NAME

BOM::Platform::Runtime::AppConfig

=head1 SYNOPSYS

    my $app_config = BOM::Platform::Runtime->instance->app_config;
    send_email() if $app_config->system->send_email_to_clients;

=head1 DESCRIPTION

This module parses configuration files and provides interface to access
configuration information.

=cut

use Moose;
use namespace::autoclean;
use YAML::XS qw(LoadFile);

use BOM::Platform::Runtime::AppConfig::Attribute::Section;
use BOM::Platform::Runtime::AppConfig::Attribute::Global;
use Data::Hash::DotNotation;

use Carp qw(croak);
use BOM::Utility::Log4perl qw( get_logger );

use BOM::System::Chronicle;

my $app_config_definitions = LoadFile('/home/git/regentmarkets/bom-platform/config/app_config_definitions.yml');

sub check_for_update {
    my $self     = shift;
    my $data_set = $self->data_set;

    my $app_settings = BOM::System::Chronicle::get('app_settings', 'binary');

    if ($app_settings and $data_set) {
        my $db_version = $app_settings->{_rev};
        unless ($data_set->{version} and $db_version and $db_version eq $data_set->{version}) {
            $self->_add_app_setttings($data_set, $app_settings);
        }
    }

    return;
}

# definitions database
has _defdb => (
    is      => 'rw',
    lazy    => 1,
    default => sub { $app_config_definitions },
);

has 'data_set' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_class {
    my $self = shift;
    $self->_create_attributes($self->_defdb, $self);
    return;
}

sub _create_attributes {
    my $self               = shift;
    my $definitions        = shift;
    my $containing_section = shift;

    $containing_section->meta->make_mutable;
    foreach my $definition_key (keys %{$definitions}) {
        $self->_validate_key($definition_key, $containing_section);
        my $definition = $definitions->{$definition_key};
        if ($definition->{isa} eq 'section') {
            $self->_create_section($containing_section, $definition_key, $definition);
            $self->_create_attributes($definition->{contains}, $containing_section->$definition_key);
        } elsif ($definition->{global}) {
            $self->_create_global_attribute($containing_section, $definition_key, $definition);
        } else {
            $self->_create_generic_attribute($containing_section, $definition_key, $definition);
        }
    }
    $containing_section->meta->make_immutable;

    return;
}

sub _create_section {
    my $self       = shift;
    my $section    = shift;
    my $name       = shift;
    my $definition = shift;

    my $writer      = "_$name";
    my $path_config = {};
    if ($section->isa('BOM::Platform::Runtime::AppConfig::Attribute::Section')) {
        $path_config = {parent_path => $section->path};
    }

    my $new_section = Moose::Meta::Class->create_anon_class(superclasses => ['BOM::Platform::Runtime::AppConfig::Attribute::Section'])->new_object(
        name       => $name,
        definition => $definition,
        data_set   => {},
        %$path_config
    );

    $section->meta->add_attribute(
        $name,
        is            => 'ro',
        isa           => 'BOM::Platform::Runtime::AppConfig::Attribute::Section',
        writer        => $writer,
        documentation => $definition->{description},
    );
    $section->$writer($new_section);

    #Force Moose Validation
    $section->$name;

    return;
}

sub _create_global_attribute {
    my $self       = shift;
    my $section    = shift;
    my $name       = shift;
    my $definition = shift;

    my $attribute = $self->_add_attribute('BOM::Platform::Runtime::AppConfig::Attribute::Global', $section, $name, $definition);
    $self->_add_dynamic_setting_info($attribute->path, $definition);

    return;
}

sub _create_generic_attribute {
    my $self       = shift;
    my $section    = shift;
    my $name       = shift;
    my $definition = shift;

    $self->_add_attribute('BOM::Platform::Runtime::AppConfig::Attribute', $section, $name, $definition);

    return;
}

sub _add_attribute {
    my $self       = shift;
    my $attr_class = shift;
    my $section    = shift;
    my $name       = shift;
    my $definition = shift;

    my $fake_name = "a_$name";
    my $writer    = "_$fake_name";

    my $attribute = $attr_class->new(
        name        => $name,
        definition  => $definition,
        parent_path => $section->path,
        data_set    => $self->data_set,
    )->build;

    $section->meta->add_attribute(
        $fake_name,
        is      => 'ro',
        handles => {
            $name          => 'value',
            'has_' . $name => 'has_value',
        },
        documentation => $definition->{description},
        writer        => $writer,
    );

    $section->$writer($attribute);

    return $attribute;
}

sub _validate_key {
    my $self    = shift;
    my $key     = shift;
    my $section = shift;

    if (grep { $key eq $_ } qw(path parent_path name definition version data_set check_for_update save_dynamic)) {
        die "Variable with name $key found under "
            . $section->path
            . ".\n$key is an internally used variable and cannot be reused, please use a different name";
    }

    return;
}

sub save_dynamic {
    my $self = shift;
    my $settings = BOM::System::Chronicle::get('app_settings', 'binary') || {};

    #Cleanup globals
    my $global = Data::Hash::DotNotation->new();
    foreach my $key (keys %{$self->dynamic_settings_info->{global}}) {
        if ($self->data_set->{global}->key_exists($key)) {
            $global->set($key, $self->data_set->{global}->get($key));
        }
    }

    $settings->{global} = $global->data;
    $settings->{_rev}   = time;
    BOM::System::Chronicle::set('app_settings', 'binary', $settings);

    return 1;
}

sub _build_data_set {
    my $self = shift;

    # relatively small yaml, so loading it shouldn't be expensive.
    my $data_set->{app_config} = Data::Hash::DotNotation->new(data => LoadFile('/etc/rmg/app_config.yml'));

    $self->_add_app_setttings($data_set, BOM::System::Chronicle::get('app_settings', 'binary') || {});

    return $data_set;
}

sub _add_app_setttings {
    my $self         = shift;
    my $data_set     = shift;
    my $app_settings = shift;

    if ($app_settings) {
        $data_set->{global} = Data::Hash::DotNotation->new(data => $app_settings->{global});
        $data_set->{version} = $app_settings->{_rev};
    }

    return;
}

has dynamic_settings_info => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { {} },
);

sub _add_dynamic_setting_info {
    my $self       = shift;
    my $path       = shift;
    my $definition = shift;

    $self->dynamic_settings_info = {} unless ($self->dynamic_settings_info);
    $self->dynamic_settings_info->{global} = {} unless ($self->dynamic_settings_info->{global});

    $self->dynamic_settings_info->{global}->{$path} = {
        type        => $definition->{isa},
        default     => $definition->{default},
        description => $definition->{description}};

    return;
}

sub BUILD {
    my $self = shift;

    $self->_build_class;

    return;
}

__PACKAGE__->meta->make_immutable;

1;

=head1 LICENSE AND COPYRIGHT

Copyright 2010 RMG Technology (M) Sdn Bhd

=cut
