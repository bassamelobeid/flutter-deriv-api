use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Warnings;

use Getopt::Long;
use JSON::MaybeUTF8 qw(:v1);
use JSON::PP;
use List::Util qw(first all);
use Path::Tiny;
use Scalar::Util qw(looks_like_number);
use Term::ANSIColor qw(colored);
use Text::Diff;
use Tie::IxHash;
use constant BASE_PATH => 'config/v3/';

GetOptions(
    fix => \(my $should_fix = 0),
);

sub read_all_schemas {
    map { chomp && {path => $_, json_text => path($_)->slurp_utf8, get_path_info($_),} } (qx{git ls-files @{[BASE_PATH]}});
}

sub get_path_info {
    my $path = shift;
    my ($method_name, $json_type) = ($path =~ m{^@{[BASE_PATH]}([a-z0-9_]+)/([a-z]+)\.json$});
    return (
        method_name    => $method_name,
        json_type      => $json_type,
        formatted_path => BASE_PATH . colored($method_name, 'cyan') . '/' . colored($json_type, 'yellow') . '.json',
    );
}

my @json_schemas = read_all_schemas();

# Test to check if the json format under the v3 folder is valid
# decoded json is used in the next subtests
subtest 'json structure' => sub {
    for my $schema (@json_schemas) {
        lives_ok(sub { $schema->{json} = decode_json_utf8($schema->{json_text}) }, 'JSON Structure is valid: ' . $schema->{formatted_path});
    }
};

=head2 general formatting and order

This mainly tests to make sure the schemas are correct in terms of:
(Displays a diff in case of error)

- Formatting:

    - Indentation uses 4 spaces
    - No space before ':', and one space after
    - No extra empty line in the middle, but empty line at the end

- Order:

    - Order of properties is:
        1. The main method name should be always the first
        2. 'required' array should be sorted the same as the order of 'properties' elements
        2. Other properties are tested recursively according to the '$order' hash below and their parent element.
        3. The rest should be ordered alphabetically (excluding enums, arrays of objects)

=cut

my $order = {
    other => {
        '$schema'            => 1,
        title                => 2,
        description          => 3,
        beta                 => 4,
        deprecated           => 4,
        hidden               => 5,
        type                 => 6,
        auth_required        => 7,
        auth_scopes          => 8,
        pattern              => 9,
        default              => 10,
        enum                 => 11,
        examples             => 12,
        additionalProperties => 13,
        required             => 14,
        properties           => 15,
        passthrough          => 101,
        req_id               => 102,
    },
    properties => {
        subscription => 101,
        passthrough  => 102,
        echo_req     => 103,
        msg_type     => 104,
        req_id       => 105,
    },
};

sub sort_elements {
    my ($ref, $parent) = @_;

    if (ref $ref eq 'ARRAY' and $parent eq 'required') {
        return [sort { ($order->{properties}{$a} // 99) <=> ($order->{properties}{$b} // 99) or $a cmp $b } @$ref];
    } elsif (
        ref $ref eq 'ARRAY' and all {
            ref eq 'HASH'
        }
        @$ref
        )
    {
        return [map { sort_elements($_) } @$ref];
    } elsif (ref $ref eq 'ARRAY' and $parent ne 'enum') {
        return [sort { looks_like_number($a); looks_like_number($a) ? $a <=> $b : $a cmp $b } @$ref];
    } elsif (ref $ref eq 'HASH') {
        my $type = ($parent // '') eq 'properties' ? $parent : 'other';
        tie my %res, 'Tie::IxHash',
            map { $_, sort_elements($ref->{$_}, $_) } sort { ($order->{$type}{$a} // 99) <=> ($order->{$type}{$b} // 99) or $a cmp $b } keys %$ref;
        return \%res;
    } else {
        return $ref;
    }
}

subtest 'general formatting and order' => sub {
    my $json = JSON::PP->new;

    $json = $json->canonical(0)->pretty(1)->indent(1)->indent_length(4)->space_before(0)->space_after(1);

    sub test_diff {
        my ($source, $result, $file_name) = @_;

        my $diff = diff \$source, \$result;

        ok !$diff, 'Schema format and order is correct: ' . $file_name;

        if ($diff) {
            print colored('Schema file is not ordered/formatted properly.', 'red'), $file_name, "\n";
            if ($should_fix) {
                print colored("The issues will automatically get fixed.\n", 'green');
            } else {
                print colored("Please make the following changes to fix the issues.\n",          'red');
                print colored('You can also run this command to automatically fix the issues: ', 'yellow'),
                    colored('perl t/005_json_structure.t --fix', 'bold'), "\n";
            }

            for (split "\n", $diff) {
                print /^-/  ? colored($_, 'red')
                    : /^\+/ ? colored($_, 'green')
                    :         $_, "\n";
            }
        }
    }

    for my $schema (@json_schemas) {
        $order->{other}{$schema->{method_name}} = $order->{properties}{$schema->{method_name}} = 0;    # Always put the main action at the beginning

        my $sorted = $json->encode(sort_elements($schema->{json}));

        test_diff($schema->{json_text}, $sorted, $schema->{formatted_path});

        delete $order->{other}{$schema->{method_name}};                                                # cleanup for next
        delete $order->{properties}{$schema->{method_name}};

        path($schema->{path})->spew_utf8($sorted) if $should_fix;
    }
};

# Make sure common properties are consistent across all schema files
subtest 'common properties' => sub {
    my $common_properties = {
        send => {
            passthrough => {
                description => '[Optional] Used to pass data through the websocket, which may be retrieved via the `echo_req` output field.',
                type        => 'object',
            },
            req_id => {
                description => '[Optional] Used to map request to response.',
                type        => 'integer',
            },
        },
        receive => {
            subscription => {
                title       => 'Subscription information',
                description => 'For subscription requests only.',
                type        => 'object',
                required    => ['id'],
                properties  => {
                    id => {
                        description => 'A per-connection unique identifier. Can be passed to the `forget` API call to unsubscribe.',
                        type        => 'string',
                        examples    => ['c84a793b-8a87-7999-ce10-9b22f7ceead3'],
                    }
                },
            },
            echo_req => {
                description => 'Echo of the request made.',
                type        => 'object',
            },
            req_id => {
                description => 'Optional field sent in request to map to response, present only when request contains `req_id`.',
                type        => 'integer',
            },
            msg_type => {
                description => 'Action name of the request made.',
                type        => 'string',
                enum        => [],
            },
        },
    };

    my $optional_properties = {
        receive => {
            subscription => 1,
        },
    };

    my $msg_type_exceptions = {
        ticks         => ['tick'],
        ticks_history => ['history', 'tick', 'candles', 'ohlc'],
    };

    for my $schema (@json_schemas) {
        my $schema_type = $schema->{json_type};
        next if $schema_type eq 'example';

        print $schema->{formatted_path}, "\n";
        for my $prop (keys $common_properties->{$schema_type}->%*) {
            my $schema_node  = $schema->{json}{properties}{$prop};
            my $node_pattern = {$common_properties->{$schema_type}{$prop}->%*};

            next if ($optional_properties->{$schema_type}{$prop} and not $schema_node);

            if ($prop eq 'msg_type') {
                my $exception_call = $msg_type_exceptions->{$schema->{method_name}};
                $node_pattern->{description} = $schema_node->{description} if $exception_call;    # description is also different for exceptions
                $node_pattern->{enum} = $exception_call // [$schema->{method_name}];
            }

            is_deeply($schema_node, $node_pattern, "\"$prop\" structure is correct.");
        }
    }
};

# Make sure every property has type and description
subtest 'type and description' => sub {

    sub check_fields {
        my ($node, $path, $errors) = @_;

        return unless ref $node eq 'HASH';

        # There would be thousands of messages since we're recursively test the
        # properties. Hence, going with this approach to suppress ok messages
        # and report only the errors.
        push $errors->{$path}->@*, "$path has type." unless $node->{type} // $node->{oneOf};
        push $errors->{$path}->@*, "$path has description." unless $node->{description};
        push $errors->{$path}->@*, "$path description starts with capital letter."
            unless $node->{description} =~ /^((\[|\()[A-Z].*(\]|\)) |)[A-Z0-9`]/;

        for my $prop_node (qw(properties patternProperties)) {
            check_fields($node->{$prop_node}{$_}, "$path->$_", $errors) for keys $node->{$prop_node}->%*;
        }

        if (ref $node->{items} eq 'HASH') {
            check_fields($node->{items}{properties}{$_}, "$path->$_", $errors) for keys $node->{items}{properties}->%*;
        }
    }

    for my $schema (@json_schemas) {
        next if $schema->{json_type} eq 'example';

        print $schema->{formatted_path}, "\n";

        my $errors = {};
        check_fields($schema->{json}, 'schema', $errors);

        if (keys $errors->%*) {
            for my $path (keys $errors->%*) {
                ok 0, $_ for $errors->{$path}->@*;
            }
        } else {
            ok 1, 'Schema fields are ok.';
        }
    }
};

# Make sure schema titles are consistent and the main method name is required
subtest 'schema titles and required' => sub {
    for my $schema (@json_schemas) {
        next unless $schema->{json_type} eq 'send';

        my $method = $schema->{method_name};
        my $receive_schema = first { $_->{method_name} eq $method && $_->{json_type} eq 'receive' } @json_schemas;

        like $schema->{json}{title},         qr/ \(request\)$/,  "$method: send.json title is correct.";
        like $receive_schema->{json}{title}, qr/ \(response\)$/, "$method: receive.json title is correct.";

        my ($send_title)    = $schema->{json}{title} =~ /(.*) \(request\)$/;
        my ($receive_title) = $receive_schema->{json}{title} =~ /(.*) \(response\)$/;
        is $receive_title, $send_title, "$method: send & receive titles are similar.";

        my $required_method = first { $_ eq $method } $schema->{json}{required}->@*;
        is $required_method, $method, "$method: method name is required.";
    }
};

#make sure auth is set
subtest 'auth scopes' => sub {
    for my $schema (@json_schemas) {
        next unless $schema->{json_type} eq 'send';
        my $method = $schema->{method_name};
        like($schema->{json}{auth_required}, qr/^(1|0)$/, "$method: auth_required is set");
        ok(defined($schema->{json}{auth_scopes}), "$method: auth_scopes is also set when Auth_required is true") if $schema->{json}{auth_required};

        my %valid_scopes = (
            read                => 1,
            trade               => 1,
            trading_information => 1,
            admin               => 1,
            payments            => 1
        );
        foreach my $schema_scope ($schema->{json}{auth_scopes}->@*) {
            ok(defined($valid_scopes{$schema_scope}), "$method :  scope $schema_scope is valid");
        }
    }
};

done_testing;
