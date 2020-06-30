## no critic (RequireExplicitPackage)
use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings

use HTML::Entities;
use BOM::Backoffice::Request qw(request);

sub get_update_volatilities_form {
    my $param = shift;
    my ($markets, $warndifference, $all_markets) = @{$param}{'selected_markets', 'warndifference', 'all_markets'};
    my @all_markets = @{$all_markets};

    my $form =
        "<form method=post action='"
        . request()->url_for('backoffice/quant/market_data_mgmt/update_volatilities/update_used_volatilities.cgi') . "'>";
    $form .= "<input type=hidden name=warndifference value='" . encode_entities($warndifference) . "'>";
    $form .= qq~Update volatility for following underlyings: <input type="text" size=30 name="markets" data-lpignore="true" value="~
        . encode_entities($markets) . qq~">~;
    $form .= qq~</br>~;
    $form .= "<input type=submit name=submit value='Go'>";
    $form .= "</form>";

    return $form;
}

sub get_update_interest_rates_form {
    my $currencies;

    my $form = "<form method=post action='" . request()->url_for('backoffice/quant/market_data_mgmt/update_used_interest_rates.cgi') . "'>";
    $form .=
        qq~Update interest rates for following currencies. E.g. AUD USD: <input type="text" size=30 name="currencies" data-lpignore="true" value="~
        . encode_entities($currencies) . qq~">~;
    $form .= "<input type=submit name=submit value='Go'>";
    $form .= "</form>";

    return $form;
}

sub generate_correlations_upload_form {
    my $args           = shift;
    my $disabled_write = shift;
    my $form;
    BOM::Backoffice::Request::template()->process(
        'backoffice/correlations_upload_form.html.tt',
        {
            broker     => $args->{broker},
            upload_url => $args->{upload_url},
            disabled   => $disabled_write,
        },
        \$form
    );
    return $form;
}
1;
