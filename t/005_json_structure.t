use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Warnings;
use JSON::MaybeUTF8 qw(:v1);
use JSON::PP;
use List::Util qw(first);
use Path::Tiny;
use Term::ANSIColor qw(colored);
use Text::Diff;

use constant BASE_PATH => 'config/v3/';

sub read_all_schemas {
    map { chomp && {
        path      => $_,
        json_text => path($_)->slurp_utf8,
        get_path_info($_),
    }} (qx{git ls-files @{[BASE_PATH]}});
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
        2. Other properties are tested recursively according to the '%order' hash below
        3. The rest should be ordered alphabetically
    - Array items are sorted alphabetically (excluding enums, arrays of objects)

=cut

subtest 'general formatting and order' => sub {
    my $json = JSON::PP->new;

    $json = $json
        ->canonical(1)
        ->pretty(1)
        ->indent(1)
        ->indent_length(4)
        ->space_before(0)
        ->space_after(1);

    my %order = (
        '$schema'            => 1,
        title                => 2,
        description          => 3,
        deprecated           => 4,
        hidden               => 5,
        type                 => 6,
        pattern              => 7,
        additionalProperties => 8,
        required             => 9,
        properties           => 10,
        echo_req             => 101,
        msg_type             => 102,
        passthrough          => 103,
        req_id               => 104,
    );

    $json = $json->sort_by(
        sub {
            ($order{$JSON::PP::a} // 99) <=> ($order{$JSON::PP::b} // 99)
                or $JSON::PP::a cmp $JSON::PP::b;
        });

    sub sort_arrays {
        my ($params) = @_;
        for my $key (keys $params->%*) {
            my $node = $params->{$key};

            if (ref $node eq 'ARRAY' && ref $node->[0] ne 'HASH' && $key ne 'enum') {
                $params->{$key} = [sort $node->@*];
            } elsif (ref $node eq 'HASH') {
                sort_arrays($node);
            }
        }
    }

    sub test_diff {
        my ($source, $result, $file_name) = @_;

        my $diff = diff \$source, \$result;

        ok !$diff, 'Schema format and order is correct: ' . $file_name;

        if ($diff) {
            print colored("Schema file is not ordered/formatted properly.\nPlease make the following changes on ", 'red'), $file_name, "\n";

            for (split "\n", $diff) {
                print /^-/  ? colored($_, 'red')
                    : /^\+/ ? colored($_, 'green')
                    :         $_, "\n";
            }
        }
    }

    for my $schema (@json_schemas) {
        $order{$schema->{method_name}} = 0;    # Always put the main action at the beginning

        sort_arrays($schema->{json});
        my $sorted = $json->encode($schema->{json});

        test_diff($schema->{json_text}, $sorted, $schema->{formatted_path});

        delete $order{$schema->{method_name}};    # cleanup for next
    }
};

# Make sure common properties are consistent across all schema files
subtest 'common properties' => sub {
    my $common_properties = {
        send => {
            passthrough => {
                type        => 'object',
                description => '[Optional] Used to pass data through the websocket, which may be retrieved via the echo_req output field.',
            },
            req_id      => {
                type        => 'integer',
                description => '[Optional] Used to map request to response.',
            },
        },
        receive => {
            echo_req => {
                type        => 'object',
                description => 'Echo of the request made.',
            },
            req_id   => {
                type        => 'integer',
                description => 'Optional field sent in request to map to response, present only when request contains req_id.',
            },
            msg_type => {
                type        => 'string',
                description => 'Action name of the request made.',
            },
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
            my $node_pattern = $common_properties->{$schema_type}{$prop};

            is $schema_node->{type},        $node_pattern->{type},        "\"$prop\" type is correct.";
            is $schema_node->{description}, $node_pattern->{description}, "\"$prop\" description is correct."
                unless ($prop eq 'msg_type' and exists $msg_type_exceptions->{$schema->{method_name}});

            if ($prop eq 'msg_type') {
                is_deeply $schema_node->{enum},
                    $msg_type_exceptions->{$schema->{method_name}} // [$schema->{method_name}],
                    "\"$prop\" value is a correct enum.";
            }
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
        push $errors->{$path}->@*, "$path has type."        unless $node->{type} // $node->{oneOf};
        push $errors->{$path}->@*, "$path has description." unless $node->{description};
        push $errors->{$path}->@*, "$path description starts with capital letter."
            unless $node->{description} =~ /^((\[|\()[A-Z].*(\]|\)) |)[A-Z0-9]/;

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

# Make sure schema titles are consistent
subtest 'schema titles' => sub {
    for my $schema (@json_schemas) {
        next unless $schema->{json_type} eq 'send';

        my $method         = $schema->{method_name};
        my $receive_schema = first { $_->{method_name} eq $method && $_->{json_type} eq 'receive' } @json_schemas;

        like $schema->{json}{title},         qr/ \(request\)$/,  "$method: send.json title is correct.";
        like $receive_schema->{json}{title}, qr/ \(response\)$/, "$method: receive.json title is correct.";

        my ($send_title)    = $schema->{json}{title}         =~ /(.*) \(request\)$/;
        my ($receive_title) = $receive_schema->{json}{title} =~ /(.*) \(response\)$/;
        is $receive_title, $send_title, "$method: send & receive titles are similar.";
    }
};

done_testing;
