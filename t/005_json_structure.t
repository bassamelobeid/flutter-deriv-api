use Test::More;
use Test::Exception;
use strict;
use warnings;
use Test::Warnings;
use JSON::MaybeXS qw/decode_json/;

# Test to check if the json format under the v3 folder is valid

subtest 'json structure' => sub {
    my $i = 1;
    for my $file (qx{git ls-files config/v3}) {
        chomp $file;
        my $json_text = do {
            open(my $json_fh, $file)
                or die("Can't open \$file\": $!\n");
            local $/;
            <$json_fh>;
        };

        print "Checking... $file\n";
        lives_ok(sub { decode_json($json_text) }, "JSON Structure valid: $file");
    }
};
done_testing;
