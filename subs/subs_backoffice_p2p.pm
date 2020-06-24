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
        $client->db->dbic->run(
            fixup => sub {
                $_->do(
                    'UPDATE p2p.p2p_advertiser SET name = ?, is_approved = ?, is_listed = ?, default_advert_description = ?, 
                        payment_info = ?, contact_info = ?, trade_band = COALESCE(?,trade_band) WHERE id = ?',
                    undef,
                    map { request->param($_) }
                        qw/advertiser_name is_approved is_listed default_advert_description payment_info contact_info trade_band advertiser_id/
                );
            });

        BOM::Platform::Event::Emitter::emit(
            p2p_advertiser_updated => {
                client_loginid => $client->loginid,
                advertiser_id  => request->param('advertiser_id'),
            },
        );

        return {
            success => 1,
            message => 'P2P advertiser for ' . $client->loginid . ' updated.'
        };
    }
    catch {
        my $error = $@;
        return {
            success => 0,
            message => 'P2P advertiser for ' . $client->loginid . ' could not be updated: ' . $error,
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
