package BOM::Test::App::HTTP;

use strict;
use warnings;

use Role::Tiny;
use BOM::Test::Helper qw/build_mojo_test/;
use BOM::Test::RPC::Client;

sub build_test_app {
    my ($self, $args) = @_;
    return build_mojo_test($args->{app});
}

sub test_schema {
    my ($self, $req_params, $expected_json_schema, $descr, $should_be_failed) = @_;

    my $c = BOM::Test::RPC::Client->new(ua => $self->{t}->app->ua);
    my $result = $c->call_ok(@$req_params)->result;

    $self->_test_schema($result, $expected_json_schema, $descr, $should_be_failed);
    return;
}

sub adjust_req_params {
    my ($self, $params, $args) = @_;
    $params->[1]->{language} = $args->{language};
    return $params;
}

1;
