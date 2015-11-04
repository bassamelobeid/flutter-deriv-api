package BOM::Platform::Account;

use strict;
use warnings;

use List::MoreUtils qw(any);
use BOM::Platform::Runtime;
use Crypt::ScryptKDF;

sub get_real_acc_opening_type {
    my $args        = shift;
    my $from_client = $args->{from_client};

    my $gaming_company    = BOM::Platform::Runtime->instance->gaming_company_for_country($from_client->residence);
    my $financial_company = BOM::Platform::Runtime->instance->financial_company_for_country($from_client->residence);

    if ($from_client->is_virtual) {
        return 'real' if ($gaming_company);

        if ($financial_company) {
            # Eg: Germany, Japan
            return $financial_company if (any { $_ eq $financial_company } qw(maltainvest japan));

            # Eg: Singapore has no gaming_company
            return 'real';
        }
    } else {
        # MLT upgrade to MF
        return $financial_company if ($financial_company eq 'maltainvest');
    }
    return;
}

# TODO: to be removed later
# Temporary only allow Japan with @binary.com email
sub invalid_japan_access_check {
    my $residence = shift // '';
    my $email     = shift // '';

    if ($residence eq 'jp' and $email !~ /\@binary\.com$/) {
        die "NOT authorized JAPAN access: $residence , $email";
    }
}

sub get_activation_code {
    my $email = shift;
    return Crypt::ScryptKDF::scrypt_b64($email, '&*%hHKDJHI$#%^@_+?><!~');
}

sub validate_activation_code {
    my ($email, $activation_code) = @_;
    return ($activation_code eq get_activation_code($email));
}

1;
