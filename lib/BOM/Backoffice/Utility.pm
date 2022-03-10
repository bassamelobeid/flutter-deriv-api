package BOM::Backoffice::Utility;

use strict;
use warnings;

use BOM::Backoffice::PlackHelpers qw( http_redirect PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::StaffPages;
use Syntax::Keyword::Try;
use Date::Utility;
use LandingCompany::Registry;

use Exporter qw(import export_to_level);

our @EXPORT_OK = qw(get_languages master_live_server_error is_valid_time get_payout_currencies);

sub get_languages {
    return {
        EN    => 'English',
        DE    => 'Deutsch',
        FR    => 'French',
        ID    => 'Indonesian',
        PL    => 'Polish',
        PT    => 'Portuguese',
        RU    => 'Russian',
        TH    => 'Thai',
        VI    => 'Vietnamese',
        ZH_CN => 'Simplified Chinese',
        ZH_TW => 'Traditional Chinese'
    };
}

=head2 is_valid_time

Routine to check if the time is a valid value & format

=over 4

=item * C<time> - Time to be checked

=back

=cut

sub is_valid_time {
    try {
        Date::Utility->new(shift);
        return 1;
    } catch {
        return 0;
    }
    return 0;
}

=head2 get_payout_currencies

Returns a reference to array of allowed payout currencies for SVG landing company

=cut

sub get_payout_currencies {
    my $legal_allowed_currencies = LandingCompany::Registry->by_name('svg')->legal_allowed_currencies;
    my @payout_currencies;

    foreach my $currency (keys %{$legal_allowed_currencies}) {
        push @payout_currencies, $currency;
    }

    # @additional_currencies is for adding additional currencies that is not available in LandingCompany('svg')->legal_allowed_currencies
    my @additional_currencies = qw(JPY CHF);
    push @payout_currencies, @additional_currencies;

    return \@payout_currencies;
}

=head2 payment_agent_column_labels

Return a hashref, mapping payment agent table columns to their display labels

=cut

sub payment_agent_column_labels {
    return +{
        payment_agent_name            => 'Payment agent name',
        url                           => 'Website URL',
        email                         => 'Email address',
        phone                         => 'Phone number',
        information                   => 'Information',
        commission_deposit            => 'Deposit commission',
        commission_withdrawal         => 'Withdrawal commission',
        is_authenticated              => 'Is authorized',
        currency_code                 => 'Currency',
        supported_banks               => 'Supported payment methods',
        min_withdrawal                => 'Minimum withdrawal limit',
        max_withdrawal                => 'Maximum withdrawal limit',
        is_listed                     => 'Listed payment agent',
        code_of_conduct_approval      => 'Code of conduct approval',
        code_of_conduct_approval_date => 'Code of conduct approval date',
        target_country                => 'Target Countries',
        affiliate_id                  => 'Affiliate id',
        status                        => 'Status',
        status_comment                => 'Status comment',
        risk_level                    => 'Risk Level',
    };
}

sub master_live_server_error {
    my $brand        = request()->brand;
    my $website_name = lc($brand->website_name);
    return main::code_exit_BO(
        "WARNING! You are not on the Master Live Server. Please go to the following link: https://collector01.$website_name/d/backoffice/f_broker_login.cgi"
    );
}

sub redirect_login {
    try {
        PrintContentType();
        BOM::StaffPages->instance->login();
    } catch {
        my $login = request()->url_for("backoffice/f_broker_login.cgi", {_r => rand()});
        print <<EOF;
<script>
    window.location = "$login";
</script>
EOF

    }
    main::code_exit_BO();
    return;
}

1;

__END__
