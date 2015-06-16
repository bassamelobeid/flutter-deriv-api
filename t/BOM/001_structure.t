use Test::More tests => 8;
use File::Basename;
use List::Util qw( first );
use List::MoreUtils qw( uniq );

use strict;
use warnings;

my $DIR = File::Basename::dirname(__FILE__) . '/../../lib/BOM/';

#in teamcity test agents we have no git repo but in dev we have
my $grep_command = 'git grep';
if (not -d "$DIR/../../.git") {
    $grep_command = 'grep -R';
}

# Everything may also use the things on its own level, of course.
my %may_use = (
#    Utility    => [],
    System   => [qw(Utility)],
    Platform => [qw(Utility System)],
    Market   => [qw(Utility System Platform)],
    Feed     => [qw(Utility System Platform Market)],
    Product  => [qw(Utility System Platform Market Feed)],
    API      => [qw(Utility System Platform Market Feed Product)],
);

my @full_list;

foreach my $layers (keys %may_use) {
    # Add self-reference.
    push @{$may_use{$layers}}, $layers;
    push @full_list, @{$may_use{$layers}};
}

@full_list = sort { $a cmp $b } uniq @full_list;
note 'Full layer list: ' . join(', ', @full_list);

foreach my $layer (sort keys %may_use) {
    my $chkdir = $DIR . $layer;
    subtest "dir $chkdir" => sub {
        my @allowed_list = @{$may_use{$layer}};
        note $layer. ' may use: ' . join(', ', @allowed_list);
        foreach my $ns (@full_list) {
            next if (first { $ns eq $_ } @allowed_list);    # Skip anything allow to be used.
            my $result = `$grep_command BOM::$ns $chkdir|wc -l`;
            $result =~ s/[\s\n]+//g;
            is($result, 0, "$layer is not using $ns [$grep_command BOM::$ns $chkdir]");
        }
    };
}

