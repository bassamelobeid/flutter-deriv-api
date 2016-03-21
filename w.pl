
#use strict;
#use warnings;

use BOM::Platform::Client;
use BOM::Platform::ProveID;
use Data::Dumper;


my $c = BOM::Platform::Client->new({loginid => 'MX35449'});

print Dumper($c);


my $premise = $c->address_1;
if ($premise =~ /^(\d+)/) {
	$premise = $1;
}

my $check = BOM::Platform::ProveID->new(
        client        => $c,
        search_option => 'ProveID_KYC',
        premise       => $premise,
        force_recheck => 1 
    )->get_result;

my $filename = '/home/shuwnyuan/MX35449/prove_ID';
my $fh;
open($fh, '>', $filename) or die "Could not open file '$filename' $!";
print $fh Dumper($check);
close $fh;


$check = BOM::Platform::ProveID->new(
        client        => $c,
        search_option => 'CheckID',
        premise       => $premise,
        force_recheck => 1 
    )->get_result;

$filename = '/home/shuwnyuan/MX35449/check_ID';
open($fh, '>', $filename) or die "Could not open file '$filename' $!";
print $fh Dumper($check);
close $fh;


