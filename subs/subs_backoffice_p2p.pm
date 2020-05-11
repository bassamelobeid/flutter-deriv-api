## no critic (RequireExplicitPackage)
use strict;
use warnings;

use Syntax::Keyword::Try;
use Data::Dumper;

use BOM::Backoffice::Request qw(request);
use BOM::RPC::v3::P2P;

sub p2p_advertiser_register {
    my $client = shift;

    try {
        $client->p2p_advertiser_create(name => request->param('advertiser_name'));

        return {
            success => 1,
            message => $client->loginid . ' has been registered as P2P advertiser.'
        };
    }
    catch {
        my ($error_code, $error_msg) = ($@, undef);

        if ($error_code =~ 'AdvertiserNameRequired') {
            $error_msg = 'P2P advertiser name is required.';
        } elsif ($error_code =~ 'AlreadyRegistered') {
            $error_msg = $client->loginid . ' is already registered as a P2P advertiser.';
        } else {
            $Data::Dumper::Terse = 1;
            $error_msg           = $client->loginid . ' could not be registered as a P2P advertiser. Error: ' . Dumper($error_code);
        }

        return {
            success => 0,
            message => $error_msg
        };
    }
}

sub p2p_advertiser_update {
    my $client = shift;

    try {
        my $advertiser = $client->p2p_advertiser_update(
            name                       => request->param('advertiser_name'),
            is_approved                => request->param('is_approved'),
            is_listed                  => request->param('is_listed'),
            default_advert_description => request->param('default_advert_description'),
            payment_info               => request->param('payment_info'),
            contact_info               => request->param('contact_info'),
        );

        BOM::Platform::Event::Emitter::emit(
            p2p_advertiser_updated => {
                client_loginid => $client->loginid,
                advertiser_id  => $advertiser->{id},
            },
        );

        return {
            success => 1,
            message => 'P2P advertiser for ' . $client->loginid . ' updated.'
        };
    }
    catch {
        my $error = $@;

        my $error_msg = 'P2P advertiser for ' . $client->loginid . ' could not be updated. ';

        if (ref $error eq 'HASH' and $BOM::RPC::v3::P2P::ERROR_MAP{$error->{error_code}}) {
            $error_msg .= ' Message: "' . $BOM::RPC::v3::P2P::ERROR_MAP{$error->{error_code}} . '", code: ' . $error->{error_code};
        } else {
            $error_msg .= 'Error: ' . Dumper($error);
        }

        return {
            success => 0,
            message => $error_msg
        };
    }
}

sub p2p_process_action {
    my $client = shift;
    my $action = shift;
    my $response;

    if ($action eq 'p2p.advertiser.register') {
        $response = p2p_advertiser_register($client);
    } elsif ($action eq 'p2p.advertiser.update') {
        $response = p2p_advertiser_update($client);
    }

    if ($response) {
        my $color = $response->{success} ? 'green' : 'red';
        my $message = $response->{message};

        return "<p style='color:$color; font-weight:bold;'>$message</p>";
    }
}

1;
