package BOM::Platform::Doughflow;

=head1 NAME

BOM::Platform::Doughflow

=head1 DESCRIPTION

A collection of static methods that related to the front-end of
our Doughflow integration.

=cut

use strict;
use warnings;

use BOM::Config::Runtime;
use BOM::Config;
use LandingCompany::Registry;

use base qw( Exporter );
our @EXPORT_OK = qw(
    get_sportsbook
    get_doughflow_language_code_for
);

sub get_sportsbook {
    my ($broker, $currency) = @_;
    my $sportsbook;

    if (not BOM::Config::on_production()) {
        return 'test';
    }

    my $landing_company = LandingCompany::Registry->get_by_broker($broker);

    if (is_deriv_sportsbooks_enabled()) {
        $sportsbook = get_sportsbook_mapping_by_landing_company($landing_company->short) . ' ' . $currency;
    } else {
        # TODO: remove this check once Doughflow's side is live
        # for backward compatibility, we keep sportsbook prefixes as 'Binary'
        my %mapping = (
            svg         => 'Binary (CR) SA',
            malta       => 'Binary (Europe) Ltd',
            iom         => 'Binary (IOM) Ltd',
            maltainvest => 'Binary Investments Ltd',
        );

        $sportsbook = $mapping{$landing_company->short} . ' ' . $currency;
    }

    return $sportsbook;
}

# defaults to English (en)
sub get_doughflow_language_code_for {
    my $lang = shift;

    # mapping b/w out lang code and doughflow code
    my %lang_code_for = (
        ZH_CN => 'zh_CHS',
        ZH_TW => 'zh_CHT',
        JA    => 'jp'
    );

    my $code = 'en';
    $lang = uc $lang;

    if (exists $lang_code_for{$lang}) {
        $code = $lang_code_for{$lang};
    } elsif (grep { $_ eq $lang } @{BOM::Config::Runtime->instance->app_config->cgi->allowed_languages}) {
        $code = lc $lang;
    }

    return $code;
}

=head2 is_deriv_sportsbooks_enabled

Returns true if doughflow Deriv sportsbooks is enabled, false otherwise

=cut

# TODO: remove this check once Doughflow's side is live
sub is_deriv_sportsbooks_enabled {
    my $self = shift;

    # is doughflow Deriv sportsbook enabled?
    return !BOM::Config::Runtime->instance->app_config->system->suspend->doughflow_deriv_sportsbooks;
}

=head2 get_sportsbook_mapping_by_landing_company

Get doughflow sportsbook name for a landing company.

Takes the following argument:

=over 4

=item * C<landing_company_shortcode> - short code of landing company

=back

Returns a sportsbook name corresponding to the landing company

=cut

sub get_sportsbook_mapping_by_landing_company {
    my $landing_company_shortcode = shift;

    my %mapping = (
        svg         => 'Deriv (SVG) LLC',
        malta       => 'Deriv (Europe) Ltd',
        iom         => 'Deriv (MX) Ltd',
        maltainvest => 'Deriv Investments Ltd'
    );

    return $mapping{$landing_company_shortcode} // '';
}

1;
