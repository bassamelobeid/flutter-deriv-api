use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Path::Tiny;
use Encode;

use BOM::Backoffice::Request qw(request);

subtest 'Unicode requests' => sub {

    my %input;
    my @blns = grep { $_ !~ /^#/ } path("/home/git/regentmarkets/bom-backoffice/t/blns.txt")->lines({chomp => 1});
    for (0 .. @blns) { $input{$_} = $blns[$_] if $blns[$_] }

    my $mock_cgi = Test::MockModule->new('CGI');
    $mock_cgi->mock(
        'param',
        sub {
            my ($self, $p) = @_;
            return $p ? Encode::encode('UTF-8', $input{$p}) : keys %input;
        });

    my $mock_request = Test::MockModule->new('BOM::Backoffice::Request::Base');
    $mock_request->mock('cgi',         sub { return CGI->new; });
    $mock_request->mock('http_method', sub { return ''; });

    my %output = %{request()->params};
    cmp_ok $output{$_}, 'eq', $input{$_} for (keys %input);
};

done_testing;

