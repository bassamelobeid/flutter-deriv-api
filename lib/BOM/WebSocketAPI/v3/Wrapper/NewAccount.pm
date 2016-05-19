package BOM::WebSocketAPI::v3::Wrapper::NewAccount;

use strict;
use warnings;

use BOM::Platform::Token::Verification;

sub verify_email_get_type_code {
    my ($c, $params) = @_;

    my $args  = $params->{call_params}->{args};
    my $email = $args->{verify_email};
    my $type  = $args->{type};
    my $code  = BOM::Platform::Token::Verification->new({
            email       => $email,
            expires_in  => 3600,
            created_for => $type,
        })->token;

    $params->{call_params}->{email} = $email;
    $params->{call_params}->{code}  = $code;
    $params->{call_params}->{type}  = $type;
    return;
}

1;
