package TestHelper;

use strict;
use warnings;
use Test::More;

use JSON::Schema;
use File::Slurp;
use Data::Dumper;

use base 'Exporter';
use vars qw/@EXPORT_OK/;
@EXPORT_OK = qw/test_schema/;

my ($version) = (__FILE__ =~ m{/(v\d+)/});
die 'unknown version' unless $version;

sub test_schema {
    my ($type, $data) = @_;

    my $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("config/$version/$type/receive.json")));
    my $result    = $validator->validate($data);
    ok $result, "$type response is valid";
    if (not $result) {
        diag Dumper(\$data);
        diag " - $_" foreach $result->errors;
    }
}