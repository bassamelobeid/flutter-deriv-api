use strict 'vars';
use BOM::Platform::Context;

sub get_update_volatilities_form {
    my ($markets, $warndifference, $all_markets) = @{$_[0]}{'selected_markets', 'warndifference', 'all_markets'};
    my @all_markets = @{$all_markets};

    my $form =
        "<form method=post action='"
        . request()->url_for('backoffice/quant/market_data_mgmt/update_volatilities/update_used_volatilities.cgi') . "'>";
    $form .= "<input type=hidden name=warndifference value='$warndifference'>";
    $form .= qq~Update volatility for following underlyings: <input type="text" size=30 name="markets" value="$markets">~;
    $form .= qq~</br>~;
    $form .= "<input type=submit name=submit value='Go'>";
    $form .= "</form>";

    return $form;
}

sub get_update_interest_rates_form {
    my $currencies;

    my $form = "<form method=post action='" . request()->url_for('backoffice/quant/market_data_mgmt/update_used_interest_rates.cgi') . "'>";
    $form .= qq~Update interest rates for following currencies. E.g. AUD USD: <input type="text" size=30 name="currencies" value="$currencies">~;
    $form .= "<input type=submit name=submit value='Go'>";
    $form .= "</form>";

    return $form;
}

sub generate_correlations_upload_form {
    my $args = shift;
    my $form;
    BOM::Platform::Context::template->process(
        'backoffice/correlations_upload_form.html.tt',
        {
           broker     => $args->{broker},
           upload_url => $args->{upload_url},
        },
        \$form
    );
    return $form;
}
1;
