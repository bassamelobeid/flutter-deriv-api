use strict 'vars';
use open qw[ :encoding(UTF-8) ];
use Devel::StackTrace;
use JSON;
use Format::Util::Numbers qw(roundnear);

sub DualControlCode_CS {
    my ($clerk, $password, $today, $clientloginid, $filetype) = @_;

    $clientloginid = uc($clientloginid);
    $clerk         = lc($clerk);

    my $a = uc(substr(BOM::Utility::md5(ucfirst("$clerk/$today $filetype")), 1, 5));

    my $b = uc(substr(BOM::Utility::md5(lcfirst("$password$clerk/$today $filetype$clientloginid" . $^T . $$)), 0, 5));

    my $c = uc(substr(BOM::Utility::md5(ucfirst($a . 'u' . $b)), 1, 5));

    return $a . $b . $c;
}

sub dual_control_code_for_file_content {
    my ($clerk, $password, $today, $file_content) = @_;

    $clerk = lc $clerk;

    my $a = uc(substr(BOM::Utility::md5(ucfirst("$clerk/$today $file_content")),                     1, 5));
    my $b = uc(substr(BOM::Utility::md5(lcfirst("$password$clerk/$today $file_content" . $^T . $$)), 0, 5));
    my $c = uc(substr(BOM::Utility::md5(ucfirst($a . 'u' . $b)),                                     1, 5));

    return $a . $b . $c;
}

sub DualControlCode {
    my ($clerk, $password, $currency, $amount, $today, $transtype, $clientloginid) = @_;

    $clientloginid = uc($clientloginid);
    $clerk         = lc($clerk);
    $transtype     = lc($transtype);
    $amount        = roundnear(0.01, $amount);

    my $a = uc(substr(BOM::Utility::md5(ucfirst("$clerk/$today $amount$currency$transtype$clientloginid")),                     1, 5));
    my $b = uc(substr(BOM::Utility::md5(lcfirst("$password$clerk/$today $amount$currency$transtype$clientloginid" . $^T . $$)), 0, 5));
    my $c = uc(substr(BOM::Utility::md5(ucfirst($a . 'u' . $b)),                                                                1, 5));
    return $a . $b . $c;
}

sub ValidDualControlCode {
    my ($code) = @_;

    if (length($code) != 15) { return 0; }
    my $a = substr($code, 0,  5);
    my $b = substr($code, 5,  5);
    my $c = substr($code, 10, 5);
    my $goodc = uc(substr(BOM::Utility::md5(ucfirst($a . 'u' . $b)), 1, 5));
    if ($c ne $goodc) { return 0; }

    return 1;
}

sub get_staff_payment_limit {
    my $cl = shift;

    my $payment_limits = JSON::from_json(BOM::Platform::Runtime->instance->app_config->payments->payment_limits);
    if (exists $payment_limits->{$cl}) {
        return $payment_limits->{$cl};
    } else {
        return 0;
    }
}

1;
