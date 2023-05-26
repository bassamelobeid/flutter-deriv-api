use strict;
use warnings;

use Test::Most;
use BOM::RPC::v3::Utility;
use BOM::Platform::Context qw(localize);
use utf8;

subtest 'validate_app_name' => sub {

    # Check valid app name
    is(BOM::RPC::v3::Utility::validate_app_name("Valid app name"), undef, "Test for valid name passed.");

    # Check invalid app names
    my @list_of_invalid_app_names = (
        "Deriv official app",
        "DERIV official app",
        "d3riv official app",
        "d3r|v official app",
        "__??dErIv??__ official app",
        "ⅾeriv official app",
        "ⓓeriv official app",
        "⒟_⒠_⒭_⒤_⒱ official app",
        "Binary_deriv official app",
        "B.inary official app",
        "_bInArY_ official app",
        "Binary_Deriv official app",
        "B.ⓘ_⒩*ᾰ?ṟ'ẙ official app",
    );

    while (defined(my $app_name = shift(@list_of_invalid_app_names))) {
        is(
            BOM::RPC::v3::Utility::validate_app_name($app_name),
            localize("App name can't include 'deriv' and/or 'binary' or words that look similar."),
            "Test for invalid name passed."
        );
    }
};

done_testing();
