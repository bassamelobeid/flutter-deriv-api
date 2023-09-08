use strict;
use warnings;
use Test::More;
use Mojo::Exception;
use BOM::OAuth::Helper qw(exception_string);

subtest 'Exception string' => sub {
    is exception_string("Error"),               "Error",         "Correct message for string";
    is exception_string(["[code]", "message"]), "[code]message", "Correct message for Array";
    is exception_string,                        "Unknown Error", "Correct message for no params";
    is exception_string({hash => "ref"}),       "Unknown Error", "Correct message for no params";
    my $e = Mojo::Exception->new('Error');
    is exception_string($e), "Error", "Correct message for Mojo::Exception";
};

done_testing();
