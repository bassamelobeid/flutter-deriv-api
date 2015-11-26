package BOM::Platform::Helper::Doughflow;

=head1 NAME

BOM::Platform::Helper::Doughflow

=head1 DESCRIPTION

A collection of static methods that related to the front-end of
our Doughflow integration.

=cut

use strict;
use warnings;

use BOM::Platform::Runtime;
use BOM::System::Config;

use base qw( Exporter );
our @EXPORT_OK = qw(
    get_sportsbook
    get_doughflow_language_code_for
);

sub get_sportsbook {
    my ($broker, $currency) = @_;
    my $sportsbook;

    if (BOM::System::Config::env ne 'production') {
        return 'test';
    }

    my $landing_company = BOM::Platform::Runtime->instance->broker_codes->landing_company_for($broker)->name;

    # remove full-stops, to make sportsbook name short enough for DF (30 chars Max)
    $landing_company =~ s/\.//g;

    $sportsbook = $landing_company . ' ' . $currency;

    # Becuase if lenght restrcition in DF part and time limit in our part, we are shortening our name dirty like this.
    if ($broker eq 'MF') {
        $sportsbook =~ s/\s\(Europe\)//g;
    }

    return $sportsbook;
}

# defaults to English (en)
sub get_doughflow_language_code_for {
    my $lang = shift;

    my $code = 'en';

    my %lang_code_for = (
        ZH_CN => 'zh_CHS'
    );

    my $code = 'en';
    if (exists $lang_code_for{$lang}) {
        $code = $lang_code_for{$lang};
    } elsif (
        grep {
            $_ eq uc $lang
        } @{BOM::Platform::Runtime->instance->app_config->cgi->allowed_languages})
    {
        $code = lc $lang;
    }
    return $code;
}

1;
