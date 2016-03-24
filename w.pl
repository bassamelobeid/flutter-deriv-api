
use strict;
use warnings;

use utf8;

#use open IO => ':utf8';



#my $str = '௵';

#my $str = '௰';
my $str = '€';

print length($str);


if ($str =~ /^[\p{Script=Common}\p{L}\s\w\@_:!-~]{0,300}$/) {
    print "matches...\n\n";
}

exit;



#my $str = 'Shuwn Yuan" 1234';
#my $str = '１−１−１';
#my $str = '福澤';

print "string length [" . length($str) . "]..\n\n";

if ($str =~ /^[\p{Script=Common}]{1,15}$/) {
    print "match sc=Common  \n\n\n";
}


if ($str =~ /^[\p{Script=Common}\p{L}]{1,15}$/) {
    print "match  sc=common & \\p{L} \n\n\n";
}


if ($str =~ /^[\p{L}]{1,15}$/) {
    print "match  \\p{L} \n\n\n";
}


if ($str =~ /^[\w\d\s]{1,15}$/) {
    print "match  \\w \n\n\n";
}


if ($str =~ /^[\p{Script=Hiragana}]{1,15}$/) {
    print "match Hiragana \n\n\n";
}

if ($str =~ /^[\p{Script=Katakana}]{1,15}$/) {
    print "match Katakana \n\n\n";
}


#if ("\N{KATAKANA-HIRAGANA DOUBLE HYPHEN}" =~ /\p{sc=Common}/) {
#    print "match ooooooo...\n\n";
#}



#print "########### \n\n\n";
#print "\N{KATAKANA-HIRAGANA DOUBLE HYPHEN}";
#print "########### \n\n\n";


$str = 'ポチポチ';
