#!/etc/rmg/bin/perl

use strict;
use warnings;

use JSON::MaybeXS;
use Path::Tiny;
use YAML qw(DumpFile);

use Binary::WebSocketAPI::Actions;

use constant SCHEMA_PATH => 'config/v3/';
use constant TARGET_PATH => $ARGV[0] // '/tmp/websockets/';

=head1 NAME

    websocket_api_list.pl

=head1 SYNOPSIS

   cd binary-websocket-api
   perl script/websocket_api_list.pl

=head1 Description

Exports a yml file with with all the API calls sorted in alphabetical order to be used in creating 
the list for the API Playground.  L< https://developers.binary.com/api/ >
It removes any calls from the list that have attribute "hidden" in the root of send.json. 
Needs to be run from the root of C<binary-websocket-api>.

=cut 

my @hidden_methods;

generate_api_list();
remove_hidden_methods();

sub generate_api_list {
    my $json = JSON::MaybeXS->new;

    my $actions = Binary::WebSocketAPI::Actions::actions_config();
    my @methods;
    my @sorted_actions = sort { $a->[0] cmp $b->[0] } @$actions; 
    for my $call (@sorted_actions) {
        my $method_name = $call->[0];

        my $send = $json->decode(path(SCHEMA_PATH, $method_name, 'send.json')->slurp_utf8);
        if ($send->{hidden}) {
            push @hidden_methods, $method_name;
            next;
        }


        my $title = $send->{title} =~ s/ \(request\)$//ir;

        push @methods,
            {
                name  => $method_name,
                title => $title
            };
    }



    my @yml = ({label=> 'All Calls', methods=> \@methods});

    $YAML::UseHeader = 0;
    path(TARGET_PATH, '_data')->mkpath;
    DumpFile(path(TARGET_PATH, '_data', 'v3.yml'), {groups => [@yml]});
}


sub remove_hidden_methods {
    path(TARGET_PATH, 'config/v3/', $_)->remove_tree for @hidden_methods;
}
