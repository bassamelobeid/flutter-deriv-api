package BOM::Backoffice::QuantsAuditEmail;

use strict;
use warnings;

use Text::SimpleTable;
use BOM::Platform::Email qw(send_email);
use BOM::Backoffice::Request qw(request);
use JSON::MaybeUTF8 qw(encode_json_utf8);

use parent 'Exporter';
our @EXPORT_OK = qw(send_trading_ops_email);

sub send_trading_ops_email {
    my $subject = shift;
    my $ref     = shift;
    my $brand   = request()->brand;

    my $tbl = Text::SimpleTable->new(30, 50);
    for my $key (sort keys %$ref) {
        my $value = $ref->{$key};
        my $type  = ref $value;
        $value = encode_json_utf8($value) if $type eq 'HASH' || $type eq 'ARRAY';
        $tbl->row($key, $value // '');
    }
    send_email({
        from                  => $brand->emails('system'),
        to                    => $brand->emails('trading_ops'),
        subject               => $subject,
        message               => ["details:<br/>", "<pre>" . $tbl->draw . "</pre>"],
        email_content_is_html => 1,
    });
}

1;

