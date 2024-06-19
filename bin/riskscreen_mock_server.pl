#!/usr/bin/env perl

use strict;
use warnings;
no indirect;

=head1 NAME

C<riskscreen_mock_server.pl>

=head1 DESCRIPTION

This scripts acts as a RiskScreen mock server in test environment. It reads mock data from /tmp/riskscreen_mock_data.yml.

=cut

use Syntax::Keyword::Try;
use IO::Async::Loop;
use WebService::Async::LexisNexis::MockServer;

try {
    my $loop = IO::Async::Loop->new;
    $loop->add(my $server =
            WebService::Async::LexisNexis::MockServer->new(mock_data_path => '/home/git/regentmarkets/bom-platform/bin/riskscreen_mock_data.yml'));

    my $port = $server->start->get;
    print "RiskScreen mock server is started. Please edit settings in third_party.yml: \n";
    print "api_url: http://localhost \n port: $port \n ";

    $loop->run;
} catch ($e) {
    use Data::Dumper;
    warn Dumper $e;
};
