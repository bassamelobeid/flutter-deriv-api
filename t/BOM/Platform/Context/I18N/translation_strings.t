use Test::Most 0.22 (tests => 15);
use Test::NoWarnings;
use Test::Warn;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use utf8;
binmode STDIN,  ":utf8";
binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

use List::Util qw(shuffle);

use BOM::Platform::Context;
use BOM::Platform::Context::I18N;
use BOM::Platform::Runtime;

foreach my $language (qw(EN AR DE ES FR ID JA PL PT RU ZH_CN VI ZH_TW IT)) {
    subtest "Testing Language : $language" => sub {
        #Force load the MakeText
        ok BOM::Platform::Context::localize("Hello, World!"), "Translation working!";
        test_language_file($language);
    };
}

sub test_language_file {
    my $language = shift;

    my $lc_lang   = lc $language;
    my $str_count = 0;
    my $handler   = BOM::Platform::Context::I18N::handle_for($lc_lang);
    my @sample    = qw(Rises Forex Charting Resources Ticks Intraday Trading Platform Prices Profit);
    $handler->encoding('UTF-8');

    for my $text (@sample) {

        if (is_valid_string($text)) {
            my $translated;
            unless (warning_is { $translated = $handler->maketext($language, $text, prepare_params($text)); } undef,
                "Successfully translated string $str_count: $text")
            {
                fail "Translation of string $text failed for language $language with parameters " . join(", ", prepare_params($text));
            }

            unless (ok $translated, 'Got some string for ' . $str_count) {
                fail "Got nothing after translation of string $text for language $language";
                diag "Params passed";
                diag "-------------";
                diag explain prepare_params($text);
                diag "-------------";
                diag "Error reported by localize";
                diag "-------------";
                $translated = $handler->maketext($language, $text, prepare_params($text));
            }
            $str_count++;
        }
    }
}

sub is_valid_string { return shift !~ /^__/; }

sub prepare_params {
    my $text = shift;
    my $how_many = () = $text =~ /_\d/g;
    return 1 .. $how_many;
}
