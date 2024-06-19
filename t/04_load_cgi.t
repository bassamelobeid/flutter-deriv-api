use strict;
use warnings;

BEGIN {
    require "./lib/BOM/Backoffice/PlackApp.pm";
    BOM::Backoffice::PlackApp::Streaming->import();
}

use Dir::Self;
use lib __DIR__ . '/..';
use Test::More;

subtest "Preload all CGIs" => sub {
    my $app = BOM::Backoffice::PlackApp::Streaming->new(
        preload => [qw/*.cgi/],
        root    => '/home/git/regentmarkets/bom-backoffice'
    )->to_app;

    ok $app, "App can be initialized with all CGIs";
};

done_testing;
