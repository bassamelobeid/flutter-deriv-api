#!/etc/rmg/bin/perl

use strict;
use warnings;

use JSON::MaybeXS;
use Path::Tiny;
use YAML qw(DumpFile);

use Binary::WebSocketAPI::Actions;

use constant SCHEMA_PATH => 'config/v3/';
use constant TARGET_PATH => $ARGV[0] // '/tmp/websockets/';

my @hidden_methods;

generate_api_list();
remove_hidden_methods();

sub generate_api_list {
    my $json = JSON::MaybeXS->new;

    my $actions = Binary::WebSocketAPI::Actions::actions_config();
    my $methods = {};

    for my $call (@$actions) {
        my $method_name = $call->[0];

        my $send = $json->decode(path(SCHEMA_PATH, $method_name, 'send.json')->slurp_utf8);
        if ($send->{hidden}) {
            push @hidden_methods, $method_name;
            next;
        }

        my $scope = $call->[1]->{require_auth} // 'unauthenticated';
        $scope = 'mt5_admin' if ($method_name =~ /^mt5_/ && $scope eq 'admin');

        my $title = $send->{title} =~ s/ \(request\)$//ir;

        push @{$methods->{$scope}},
            {
                name  => $method_name,
                title => $title
            };
    }

    $methods->{$_} = [sort { $a->{title} cmp $b->{title} } $methods->{$_}->@*] for keys $methods->%*;

    # Groups in the same order that we want to display
    my @groups = ('unauthenticated', 'read', 'trade', 'admin', 'payments', 'mt5_admin',);

    my @yml = map { {label => make_label($_), methods => $methods->{$_}} } @groups;

    $YAML::UseHeader = 0;
    path(TARGET_PATH, '_data')->mkpath;
    DumpFile(path(TARGET_PATH, '_data', 'v3.yml'), {groups => [@yml]});
}

sub make_label {
    my ($group) = @_;
    return
          $group eq 'unauthenticated' ? "Unauthenticated Calls"
        : $group eq 'mt5_admin'       ? "MT5-related Calls: 'admin' scope"
        :                               "Authenticated Calls: '$group' scope";
}

sub remove_hidden_methods {
    path(TARGET_PATH, 'config/v3/', $_)->remove_tree for @hidden_methods;
}
