#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use HTML::Entities;
use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit      ();
use BOM::Backoffice::Cookie;
use BOM::User::AuditLog;
use BOM::DualControl;
BOM::Backoffice::Sysinit::init();

use Scalar::Util    qw(looks_like_number);
use JSON::MaybeUTF8 qw(encode_json_utf8);

my $clerk = BOM::Backoffice::Auth::get_staffname();
my $title = 'Make dual control code';
my $now   = Date::Utility->new;
my $input = request()->params;

my $json_payload = {
    symbol              => $input->{symbol},
    lb_period           => $input->{index_params_lb_period},
    lb_period_secondary => $input->{index_params_lb_period_secondary},
    buy_leverage        => $input->{index_params_buy_leverage},
    sell_leverage       => $input->{index_params_sell_leverage},
    upper_level         => $input->{index_params_upper_level},
    lower_level         => $input->{index_params_lower_level},
    rebalancing_tick    => $input->{index_params_rebalancing_tick},
    transition_state    => $input->{index_params_transition_state}};

sub form_validation {
    my $json_payload      = shift;
    my $validation_errors = 0;
    for my $field (keys $json_payload->%*) {
        next if $field eq 'symbol';
        next if $field eq 'transition_state';
        my $value = $json_payload->{$field};
        my $is_number;
        my $is_positive;

        unless ($value) {
            print "$field is empty <br>";
        } else {
            $is_number   = looks_like_number($value);
            $is_positive = ($value >= 0) ? 1 : 0;

            print "$field must be a number bigger than 0 <br>" unless $is_number && $is_positive;

        }

        $validation_errors++ unless $is_number && $is_positive;
    }

    return $validation_errors;
}

unless (form_validation($json_payload)) {
    Bar($title);
    my $code = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => 'QuantsDCC'
        })->tactical_index_control_code(encode_json_utf8($json_payload));

    my $message =
        "The dual control code created by $clerk " . " is: $code This code is valid for 1 hour (from " . $now->datetime_ddmmmyy_hhmmss . ") only.";

    BOM::User::AuditLog::log($message, '', $clerk);

    print '<p>'
        . 'DCC: (single click to copy)<br>'
        . '<div class="dcc-code copy-on-click">'
        . encode_entities($code)
        . '</div><script>initCopyText()</script><br>'
        . 'This code is valid for 1 hour from now: UTC '
        . Date::Utility->new->datetime_ddmmmyy_hhmmss . '<br>'
        . 'Creator: '
        . $clerk . '<br>';

    sub print_error {
        my $err = shift;
        print "<p>$err</p>";
    }

    code_exit_BO();
}
