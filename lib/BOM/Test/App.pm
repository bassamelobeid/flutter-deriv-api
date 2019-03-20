package BOM::Test::App;

use strict;
use warnings;

use Moo;

use Data::Dumper;
use JSON::MaybeXS;
use Test::More;
use JSON::Validator;
sub BUILD {
    my ($self, $args) = @_;

    my $role_name =
          $args->{app} =~ /RPC/        ? 'HTTP'
        : $args->{app} =~ /websocket/i ? 'WebSocket'
        :                                '';

    Moo::Role->apply_roles_to_object($self, 'BOM::Test::App::' . $role_name);

    $self->{t} = $self->build_test_app($args);

    return $self;
}

sub _test_schema {
    my ($self, $result, $expected_json_schema, $descr, $should_be_failed) = @_;

    my $validator  = JSON::Validator->new();
    $validator->schema(JSON::MaybeXS->new->decode($expected_json_schema));
    #   $validator->coerce(strings => 1, numbers =>1, booleans => 1);

    my @error      = $validator->validate($result);
    my $test_level = $Test::Builder::Level;
    local $Test::Builder::Level = $test_level + 3;
    if ($should_be_failed) {
        ok(scalar(@error), "$descr response is valid while it must fail.");
        if (!@error) {
            diag Dumper({'Got response' => $result});
            }
    } else {
        ok !scalar(@error), "$descr response is valid";
        if (@error) {
            diag Dumper({'Got response' => $result});
            diag " - $_" foreach @error;
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
