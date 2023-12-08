package Binary::WebSocketAPI::FastSchemaValidator;
use strict;
use warnings;
use Data::Dumper;
use Syntax::Keyword::Try;
use JSON::PP;

sub _die_at_path {
    my ($path, $message) = @_;
    my $path_str = scalar(@$path) == 0 ? "Top Level JSON" : "JSON Path: " . join('::', @$path);
    die "$message at: $path_str";
}

sub _check_for_unknown_keys {
    my ($path, $schema, $allowed_keys) = @_;
    my %allowed_keys_hash = map { $_ => 1 } @$allowed_keys;
    for my $key (sort keys %$schema) {
        if (!defined($allowed_keys_hash{$key})) {
            _die_at_path $path, "Unknown entry $key";
        }
    }
}

sub _get_required_value_for_key {
    my ($path, $schema, $key) = @_;
    if (!defined($schema->{$key})) {
        _die_at_path $path, "Missing entry $key";
    }
    return $schema->{$key};
}

sub _get_value_for {
    my ($path, $schema, $key, $default) = @_;
    if (!defined($schema->{$key})) {
        return $default;
    }
    return $schema->{$key};
}

sub _prepare_fast_validate_part {
    my ($path, $schema) = @_;
    my @ignored_validator_extensions = ('auth_scopes', 'auth_required', 'hidden', 'sensitive');
    my @basic_keys                   = ('$schema', '$id', 'title', 'description', 'type', 'examples', 'auth_required', @ignored_validator_extensions);
    my $type                         = _get_required_value_for_key($path, $schema, 'type');
    my $allow_null                   = undef;
    if (ref($type) eq "ARRAY") {
        if (scalar(@$type) == 2 and $type->[0] eq "null") {
            $type       = $type->[1];
            $allow_null = 1;
        } elsif (scalar(@$type) == 2 and $type->[1] eq "null") {
            $type       = $type->[0];
            $allow_null = 1;
        } else {
            _die_at_path $path, "Unsupported type array (we only support one type and null): " . join(",", @$type);
        }
    }
    if ($type eq 'object') {
        _check_for_unknown_keys($path, $schema,
            [@basic_keys, 'properties', 'required', 'additionalProperties', 'patternProperties', 'minProperties', 'maxProperties']);
        my $additional_properties;
        my $pattern_properties = {};

        if (exists($schema->{'additionalProperties'})) {
            my $additional_properties_schema = _get_value_for($path, $schema, 'additionalProperties', undef);
            if (JSON::PP::is_bool($additional_properties_schema) and (!$additional_properties_schema)) {
                $additional_properties = {mode => 'allow'};    #User chose to ignore
            } else {
                $additional_properties = {
                    mode   => 'check',
                    schema => _prepare_fast_validate_part([@$path, 'additionalProperties'], $additional_properties_schema)};
            }
        } else {
            $additional_properties = {mode => 'allow'};    #Allow any if the key does not exist
        }

        if (exists($schema->{'patternProperties'})) {
            foreach my $pattern (keys %{$schema->{'patternProperties'}}) {
                my $pattern_schema = $schema->{'patternProperties'}->{$pattern};
                $pattern_properties->{$pattern} = _prepare_fast_validate_part([@$path, 'patternProperties'], $pattern_schema);
            }
        }

        my $fields     = undef;
        my $properties = _get_value_for($path, $schema, 'properties', undef);
        if (defined($properties)) {
            foreach my $field_name (keys %$properties) {
                my $field_schema = $properties->{$field_name};
                $fields->{$field_name} = _prepare_fast_validate_part([@$path, $field_name], $field_schema);
            }
        }

        my %required = map { $_ => 1 } _get_value_for($path, $schema, 'required', [])->@*;
        return {
            type                  => "object",
            fields                => $fields,
            required              => \%required,
            additional_properties => $additional_properties,
            pattern_properties    => $pattern_properties,
            allow_null            => $allow_null,
            min_properties        => _get_value_for($path, $schema, 'minProperties', undef),
            max_properties        => _get_value_for($path, $schema, 'maxProperties', undef),
        };
    } elsif ($type eq 'array') {
        _check_for_unknown_keys($path, $schema, [@basic_keys, 'items']);
        my $item_schema = _get_value_for($path, $schema, 'items', undef);
        my $items       = defined($item_schema) ? _prepare_fast_validate_part([@$path, 'items'], $item_schema) : undef;
        return {
            type       => "array",
            items      => $items,
            allow_null => $allow_null
        };
    } elsif ($type eq 'string' or $type eq 'integer' or $type eq 'number') {
        my @extra_fields;
        if ($type eq 'integer' or $type eq 'number') {
            push @extra_fields, 'maximum', 'minimum';
        } elsif ($type eq 'string') {
            push @extra_fields, 'maxLength', 'pattern';
        }
        _check_for_unknown_keys($path, $schema, [@basic_keys, 'enum', 'default', @extra_fields]);
        my $ret = {allow_null => $allow_null};
        $ret->{maximum}   = _get_value_for($path, $schema, 'maximum')   if (defined(_get_value_for($path, $schema, 'maximum',   undef)));
        $ret->{minimum}   = _get_value_for($path, $schema, 'minimum')   if (defined(_get_value_for($path, $schema, 'minimum',   undef)));
        $ret->{maxLength} = _get_value_for($path, $schema, 'maxLength') if (defined(_get_value_for($path, $schema, 'maxLength', undef)));
        $ret->{pattern}   = _get_value_for($path, $schema, 'pattern')   if (defined(_get_value_for($path, $schema, 'pattern',   undef)));

        my $enum = _get_value_for($path, $schema, 'enum', undef);
        if (!defined($enum)) {
            $ret->{type} = $type;
        } else {
            for my $v (@$enum) {
                _die_at_path($path, "Unsupported null value in enum")         unless defined($v);
                _die_at_path($path, "Invalid value $v in enum of type $type") unless _check_basic_type($type, $v);
            }
            my %values = map { _coerce_basic_type($type, $_) => 1 } @$enum;
            $ret->{type}   = "enum_$type";
            $ret->{values} = \%values;
        }

        my $default = _get_value_for($path, $schema, 'default', undef);
        if (defined($default)) {
            _die_at_path($path, "Invalid default value '$default' for type $type") unless _check_basic_type($type, $default);
            $ret->{default} = _coerce_basic_type($type, $default);
        }

        return $ret;
    } else {
        _die_at_path $path, "Unknown type $type";
    }
}

=head2 prepare_fast_validate

Description
Given a JSON schema attempt attempt to turn it into a fast_schema usable by this module. Not all schemas are supported, and
this method can be used to check if a schema is supported.

=over 4

=item  * C<schema>   hash - the redis schema - parsed into an object, by decode_json_utf8() so that JSON::PP::is_bool() returns true for the JSON value false

=back

Returns ($fast_schema, $error_str) - if the fast_schema is undef then error will be filled. If the schema is defined
then the error should be the empty string, and the fast_schema object can be used with calls to fast_validate_and_coerce

=cut

sub prepare_fast_validate {
    my ($schema) = @_;
    try {
        my $fast_schema = _prepare_fast_validate_part([], $schema);
        return ($fast_schema, "");
    } catch ($e) {
        return (undef, $e);
    }

}

sub _get_type_description {
    my ($message) = @_;
    my $type_descriptions = {
        q{}   => 'Scalar',
        HASH  => 'Object',
        ARRAY => 'Array',
    };
    my $ref_type = ref $message;
    return $type_descriptions->{$ref_type} // $ref_type;
}

sub _check_basic_type {
    my ($type, $value) = @_;
    if ($type eq "integer") {
        return ($value =~ /^-?(0|[1-9][0-9]*)$/) || ($value =~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?[eE](\+?[0-9]+)$/);    #Allow exponent, but only positive
    } elsif ($type eq "number") {
        return ($value =~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?$/) || ($value =~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?[eE]([\-\+]?[0-9]+)$/);
    } elsif ($type eq "string") {
        return 1;
    } else {
        die "Internal error unknown basic type $type #4235423";
    }

}

sub _coerce_basic_type {
    my ($type, $value) = @_;
    if ($type eq "integer") {
        return int($value);
    } elsif ($type eq "number") {
        return $value + 0;
    } elsif ($type eq "string") {
        return $value . "";
    } else {
        die "Internal error unknown basic type $type #4235423";
    }

}
# Check the JSON pattern - this matches the behavior of JSON::Validator and treats it as a perl regexp (the json schema spec specifies ECMA regex)
sub _check_pattern {
    my ($pattern, $str) = @_;
    return $str =~ /$pattern/;
}

sub _fast_validate_and_coerce_part {
    my ($path, $fast_schema, $messageRef) = @_;
    my $type = $fast_schema->{'type'};
    if (!defined($$messageRef)) {
        if ($fast_schema->{'allow_null'}) {
            return;    #Null is allowed here
        }
        _die_at_path($path, "Expected $type, found: null");
    } elsif ($type eq "string" or $type eq "integer" or $type eq "number") {
        _die_at_path($path, "Expected $type, found: " . _get_type_description($$messageRef)) unless ref($$messageRef) eq "";

        _die_at_path($path, "Invalid $type: " . $$messageRef) unless _check_basic_type($type, $$messageRef);

        _die_at_path($path, "Value bigger than maximum (" . $fast_schema->{maximum} . "): " . $$messageRef)
            if defined($fast_schema->{maximum})
            and $$messageRef > $fast_schema->{maximum};

        _die_at_path($path, "Value smaller than minimum (" . $fast_schema->{minimum} . "): " . $$messageRef)
            if defined($fast_schema->{minimum})
            and $$messageRef < $fast_schema->{minimum};

        _die_at_path($path, "Value too long, greater than maximum (" . $fast_schema->{maxLength} . "): " . $$messageRef)
            if defined($fast_schema->{maxLength})
            and length($$messageRef) > $fast_schema->{maxLength};

        _die_at_path($path, "Value does not match pattern (" . $fast_schema->{pattern} . "): " . $$messageRef)
            if defined($fast_schema->{pattern})
            and (!_check_pattern($fast_schema->{pattern}, $$messageRef));

        $$messageRef = _coerce_basic_type($type, $$messageRef);
    } elsif ($type eq "enum_string" or $type eq "enum_integer" or $type eq "enum_number") {
        my $basic_type = (split(/_/, $type))[1];
        _die_at_path($path, "Expected $basic_type, found: " . _get_type_description($$messageRef)) unless ref($$messageRef) eq "";

        _die_at_path($path, "Expected $basic_type in enum list, found: " . $$messageRef)
            unless _check_basic_type($basic_type, $$messageRef);

        _die_at_path($path, "Expected $basic_type in enum list, found: " . $$messageRef)
            unless defined($fast_schema->{'values'}->{_coerce_basic_type($basic_type, $$messageRef)});

        $$messageRef = _coerce_basic_type($basic_type, $$messageRef);
    } elsif ($type eq "object") {
        _die_at_path($path, "Expected object, found: nothing") unless defined($$messageRef);

        _die_at_path($path, "Expected object, found: " . _get_type_description($$messageRef)) unless ref $$messageRef eq "HASH";

        _die_at_path($path, "Object, contains " . scalar(keys(%$$messageRef)) . " properties, max allowed " . $fast_schema->{max_properties})
            if defined($fast_schema->{max_properties})
            and scalar(keys(%$$messageRef)) > $fast_schema->{max_properties};

        _die_at_path($path, "Object, contains " . scalar(keys(%$$messageRef)) . " properties, min allowed " . $fast_schema->{min_properties})
            if defined($fast_schema->{min_properties})
            and scalar(keys(%$$messageRef)) < $fast_schema->{min_properties};

        if (defined($fast_schema->{fields})) {
            for my $field_name (keys %{$fast_schema->{fields}}) {
                my $field_defintion = $fast_schema->{fields}->{$field_name};
                if (defined($fast_schema->{required}->{$field_name})) {
                    _die_at_path($path, "Missing element '$field_name'") unless exists($$messageRef->{$field_name});
                }
                if (exists($$messageRef->{$field_name})) {
                    _fast_validate_and_coerce_part([@$path, $field_name], $field_defintion, \$$messageRef->{$field_name});
                } elsif (exists($field_defintion->{default})) {
                    $$messageRef->{$field_name} = $field_defintion->{default};
                }
            }
        }

        for my $field_name (keys %$$messageRef) {
            if (!defined($fast_schema->{fields}->{$field_name})) {
                my $matched = undef;
                foreach my $pattern (keys %{$fast_schema->{'pattern_properties'}}) {
                    if (_check_pattern($pattern, $field_name)) {
                        _fast_validate_and_coerce_part(
                            [@$path, $field_name],
                            $fast_schema->{'pattern_properties'}->{$pattern},
                            \$$messageRef->{$field_name});
                        $matched = 1;
                    }
                }
                if (!$matched) {
                    my $additional_properties = $fast_schema->{'additional_properties'};
                    if ($additional_properties->{mode} eq "reject") {
                        _die_at_path($path, "Unexpected element '$field_name'");
                    } elsif ($additional_properties->{mode} eq "check") {
                        _fast_validate_and_coerce_part([@$path, $field_name], $additional_properties->{schema}, \$$messageRef->{$field_name});
                    } elsif ($additional_properties->{mode} eq "allow") {
                        # allow anything
                    } else {
                        _die_at_path($path,
                            "Internal error #39742424 additional property mode '" . ($additional_properties->{mode} // "undef") . "'");
                    }
                }
            }
        }
    } elsif ($type eq "array") {
        _die_at_path($path, "Expected array, found: nothing") unless defined($$messageRef);

        _die_at_path($path, "Expected array, found: " . _get_type_description($$messageRef)) unless ref $$messageRef eq "ARRAY";

        my $element_schema = $fast_schema->{items};
        if (defined($element_schema)) {
            for (my $ii = 0; $ii < scalar(@$$messageRef); $ii++) {
                _fast_validate_and_coerce_part([@$path, "item_$ii"], $element_schema, \$$messageRef->[$ii]);
            }
        }
    } else {
        _die_at_path($path, "Internal error #6891242 unkown type '$type'");
    }

}

=head2 fast_validate_and_coerce

Description
Given a fast_schema and a message, validate the message with the schema, and coerce the types in the message to
the ones defined in the schema.

=over 4

=item  * C<fast_schema>   hash_ref - the fast_schema as returned by prepare_fast_validate

=item  * C<message>   hash_ref - the object to be checked

=back

Returns undef if the message matches the schema, and an error string if there is a problem with the message.
If undef is returned the types will have been coerced. If an error is returned the message may have been 
partially coerced.

=cut

sub fast_validate_and_coerce {
    my ($fast_schema, $message) = @_;
    if (!defined($fast_schema)) {
        return "Missing schema";
    }

    try { _fast_validate_and_coerce_part([], $fast_schema, \$message) }
    catch ($e) {
        return $e;
    }
    return undef;    #Schema is valid
}

1;
