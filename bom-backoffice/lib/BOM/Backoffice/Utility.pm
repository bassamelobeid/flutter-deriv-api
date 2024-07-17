package BOM::Backoffice::Utility;

use strict;
use warnings;

use BOM::Backoffice::PlackHelpers qw( http_redirect PrintContentType );
use BOM::Backoffice::Request      qw(request);
use BOM::StaffPages;
use Syntax::Keyword::Try;
use Date::Utility;
use LandingCompany::Registry;
use Time::Piece;

use Exporter qw(import export_to_level);

our @EXPORT_OK =
    qw(update_self_exclusion_time_settings get_languages master_live_server_error is_valid_time is_valid_date_time get_payout_currencies);
use constant exclude_date => {
    "EXCLUDEUNTIL" => "exclude_until",
    "TIMEOUTUNTIL" => "timeout_until"
};

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

Routine to check if the given value is a valid time and the format is H:M:S (21:30:30)

=over 4

=item * C<time> - Time to be checked

=back

=cut

sub is_valid_time {
    try {
        return Time::Piece->strptime(shift, "%H:%M:%S");
    } catch {
        return 0;
    }

    return 0;
}

=head2 is_valid_date_time

Routine to check if the datetime is a valid value & format

=over 4

=item * C<datetime> - Datetime to be checked

=back

=cut

sub is_valid_date_time {
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
        urls                          => 'Website URL',
        email                         => 'Email address',
        phone_numbers                 => 'Phone number',
        information                   => 'Information',
        commission_deposit            => 'Deposit commission',
        commission_withdrawal         => 'Withdrawal commission',
        currency_code                 => 'Currency',
        supported_payment_methods     => 'Supported payment methods',
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

=head2 transform_summary_status_to_html

transform statuses to html

=cut

sub transform_summary_status_to_html {
    my ($summaries, $status_op) = @_;
    my $result = '';
    for my $summary ($summaries->@*) {
        my $status = $summary->{status};
        my $ids    = $summary->{ids};
        if ($summary->{passed}) {

            $result .= "<div class='notify'><b>SUCCESS :</b>&nbsp;&nbsp;<b>$status</b>&nbsp;&nbsp;has been ";
            if ($status_op eq 'remove') {
                $result .= "removed from";
            } elsif (grep { $status_op eq $_ } ('remove', 'remove_siblings')) {
                $result .= "removed from siblings";
            } elsif (grep { $status_op eq $_ } ('sync', 'sync_accounts')) {
                $result .= "copied to siblings";
            }
            $result .= " <b>$ids</b></div>";
        } else {
            my $is_error_hash = ref($summary->{error}) eq 'HASH';

            my $error_to_append =
                  $is_error_hash
                ? $summary->{error}->{description} // $summary->{error}->{error_msg}
                : (($summary->{error} // '') =~ s/\s+at\s+.+//r);

            my $failing_rule = $is_error_hash ? $summary->{error}->{failing_rule} : 'N/A';

            my $fail_op = 'process';
            $fail_op = 'remove'               if $status_op eq 'remove';
            $fail_op = 'remove from siblings' if $status_op eq 'remove_siblings';
            $fail_op = 'copy to siblings'     if $status_op eq 'sync';
            $fail_op = 'copy to accounts'     if $status_op eq 'sync_accounts';
            $fail_op = 'remove from accounts' if $status_op eq 'remove_accounts';
            $result .=
                "<div class='notify notify--danger'><b>ERROR :</b>&nbsp;&nbsp;Failed to $fail_op, status <b>$status</b> for $ids. Please try again.</div>";
            $result .= $summary->{error}
                ? "<div class='notify notify--danger'><b>Failed Because</b> : "
                . ($error_to_append // "Some error occured in $fail_op")
                . ".</div>
            <div class='notify notify--danger'><b>Failed Rule</b> : $failing_rule.</div>"
                : '';
        }

    }
    return $result;
}

=head2 write_access_groups

Return all the groups we have in backoffice with write access

=cut

sub write_access_groups {
    return qw(AntiFraud CSWrite Compliance P2PWrite Payments QuantsWrite DealingWrite AccountsAdmin AccountsLimited);
}

=head2 update_self_exclusion_time_settings

update self_exlusion settings for date type fields

=cut

sub update_self_exclusion_time_settings {
    my ($client) = @_;
    for my $field (qw(EXCLUDEUNTIL TIMEOUTUNTIL)) {
        my $date_until  = request()->param($field) || undef;
        my $field_param = exclude_date->{$field};

        for my $sibling_id ($client->user->bom_real_loginids) {

            my $sibling = BOM::User::Client::get_instance({'loginid' => $sibling_id});

            $date_until = Date::Utility->new($date_until)->epoch if $date_until;

            $sibling->set_exclusion->$field_param($date_until);

            $sibling->save;
        }
    }
}

=head2 get_office_countries

Returns country codes of all Deriv offices.

=cut

sub get_office_countries {
    return qw(my gb fr mt cy gg de hk sg jo ae py rw ky vg vu);
}

1;

__END__
