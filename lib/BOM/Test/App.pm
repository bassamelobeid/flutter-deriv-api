package BOM::Test::App;

use strict;
use warnings;

use Moo;
use Role::Tiny::With;

use Data::Dumper;
use JSON;
use Test::More;

sub BUILD {
    my ($self, $args) = @_;

    my $role_name =
          $args->{app} =~ /RPC/        ? 'HTTP'
        : $args->{app} =~ /websocket/i ? 'WebSocket'
        :                                '';

    Role::Tiny->apply_roles_to_object($self, 'BOM::Test::App::' . $role_name);

    $self->{t} = $self->build_test_app($args);

    return $self;
}

sub _test_schema {
    my ($self, $result, $expected_json_schema, $descr, $should_be_failed) = @_;

    my $validator = JSON::Schema->new(JSON::from_json($expected_json_schema));
    my $valid     = $validator->validate($result);
    local $Test::Builder::Level += 3;
    # ok $valid, $descr;
    # if (not $valid) {
    #     diag Dumper({'Got response' => $result});
    #     diag " - $_" foreach $valid->errors;
    # }
    if ($should_be_failed) {
        ok(!$valid, "$descr response is valid while it must fail.");
        if ($valid) {
            diag Dumper({'Got response' => $result});
            diag " - $_" foreach $valid->errors;
        }
    } else {
        ok $valid, "$descr response is valid";
        if (not $valid) {
            diag Dumper({'Got response' => $result});
            diag " - $_" foreach $valid->errors;
        }
    }
    return;
}

1;
