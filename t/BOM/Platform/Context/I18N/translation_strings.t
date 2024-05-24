use Test::Most 0.22 (tests => 22);
use Test::Warn;
use Test::MockModule;
use Test::Warnings;
use File::Spec;

use utf8;
binmode STDIN,  ":utf8";
binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

use List::Util qw(shuffle);

use BOM::Platform::Context;
use BOM::Platform::Context::I18N;
use BOM::Config::Runtime;

my @languages = qw(EN DE ES FR ID PL PT RU ZH_CN VI ZH_TW IT TH TR KO AR BN SI SW);

is @{BOM::Config::Runtime->instance->app_config->cgi->supported_languages}, @languages, "correct number of languages";

foreach my $language (@languages) {
    subtest "Testing Language : $language" => sub {
        #Force load the MakeText
        ok BOM::Platform::Context::localize("Hello, World!"), "Translation working!";
        test_language_file($language);
        test_contract_longcodes($language);
    };
}

subtest "Test different input types" => sub {
    is BOM::Platform::Context::localize('Barriers must be on either side of the spot.'), 'Barriers must be on either side of the spot.',
        'Correct translation for basic string';
    is BOM::Platform::Context::localize('Barrier must be at least [plural,_1,%d pip,%d pips] away from the spot.', 10),
        'Barrier must be at least 10 pips away from the spot.', 'Correct translation for basic string with parameters';
    is BOM::Platform::Context::localize(['Barrier must be at least [plural,_1,%d pip,%d pips] away from the spot.', 10]),
        'Barrier must be at least 10 pips away from the spot.', 'Correct translation for array ref with string and simple params';
    my $longcode =
        ['Win payout if [_3] is strictly lower than [_6] at [_5].', 'USD', '166.27', 'GBP/USD', [], ['close on [_1]', '2016-05-13'], ['entry spot']];
    is BOM::Platform::Context::localize($longcode),
        'Win payout if GBP/USD is strictly lower than entry spot at close on 2016-05-13.',
        'Correct translation for array ref with string and nested params';
    my $same_longcode =
        ['Win payout if [_3] is strictly lower than [_6] at [_5].', 'USD', '166.27', 'GBP/USD', [], ['close on [_1]', '2016-05-13'], ['entry spot']];
    cmp_deeply($longcode, $same_longcode, "localize kept input unchanged");
};

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
    my $text     = shift;
    my $how_many = () = $text =~ /_\d/g;
    return 1 .. $how_many;
}

sub test_contract_longcodes {
    my $language = shift;

    my $lc_lang = lc $language;
    my $handler = BOM::Platform::Context::I18N::handle_for($lc_lang);
    my $longcode =
        'For \'Long\', you receive a payout in 7 ticks if the spot price of Volatility 100 (1s) Index never touches or drops below entry spot minus 30.36. Your payout is equal to 0.93933 multiplied by the absolute difference between the final price and entry spot minus 30.36. If you choose your duration in number of ticks, you won\'t be able to terminate your contract early.';
    $handler->encoding('UTF-8');

    my $translated;

    unless (warning_is { $translated = $handler->maketext($longcode); } undef, "Successfully translated longcode $longcode") {
        fail "Translation of longcode - $longcode failed for language $language ";
    }

}
