package BOM::Test::App;

use strict;
use warnings;

use Moo;
use Role::Tiny::With;

use Data::Dumper;
use JSON::MaybeXS;
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

    my $validator  = JSON::Schema->new(JSON::MaybeXS->new->decode($expected_json_schema));
    my $valid      = $validator->validate($result);
    my $test_level = $Test::Builder::Level;
    local $Test::Builder::Level = $test_level + 3;
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
    return $result;
}

sub is_websocket {
    my ($self) = @_;
    return ref($self) =~ /websocket/i;
}

sub adjust_req_params {
    my ($self, $req_params) = @_;
    return $req_params;
}

1;
