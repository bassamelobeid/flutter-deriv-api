package BOM::RPC::v3::IdentityVerification;

use strict;
use warnings;

use List::Util qw( any );
use Syntax::Keyword::Try;

use BOM::Rules::Engine;
use BOM::Platform::Context qw(localize);
use BOM::Platform::Event::Emitter;
use BOM::Platform::Utility;
use BOM::RPC::Registry '-dsl';
use BOM::User::IdentityVerification;

use Brands::Countries;

=head2 identity_verification_document_add

Submits provided document information for authenticated user in order for IDV later uses.

Looking for the following arguments:

=over 4

=item * C<issuing_country> - The 2-letter country code which document issued in.

=item * C<document_type> - The type of the document e.g. national_id, passport, etc.

=item * C<document_number> - An alpha-numeric value as document identification number

=item * C<document_additional> - (optional) Additional information some document types may require.

=back

Returns 1 if the procedure was successful. 

=cut

requires_auth('trading', 'wallet');

rpc identity_verification_document_add => sub {
    my $params = shift;

    my $args   = $params->{args};
    my $client = $params->{client};

    my $issuing_country = lc($args->{issuing_country} // '');
    my $document_type   = lc($args->{document_type}   // '');
    my $document_number = $args->{document_number}     // '';
    my $additional      = $args->{document_additional} // '';

    my $rule_engine = BOM::Rules::Engine->new(
        client          => $client,
        stop_on_failure => 1
    );

    try {
        $rule_engine->verify_action(
            'idv_add_document',
            loginid             => $client->loginid,
            issuing_country     => $issuing_country,
            document_type       => $document_type,
            document_number     => $document_number,
            document_additional => $additional,
        );
    } catch ($err) {
        return BOM::RPC::v3::Utility::rule_engine_error($err);
    };

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);
    $idv_model->claim_expired_document_chance() if $idv_model->has_expired_document_chance() && $idv_model->submissions_left() == 0;

    my $countries         = Brands::Countries->new;
    my $configs           = $countries->get_idv_config($issuing_country);
    my $additional_config = $configs->{document_types}->{$document_type}->{additional};

    $idv_model->add_document({
        issuing_country => $issuing_country,
        number          => $document_number,
        type            => $document_type,
        $additional_config ? (additional => $additional) : (),
    });

    $idv_model->identity_verification_requested($client);

    return 1;
};

1;
