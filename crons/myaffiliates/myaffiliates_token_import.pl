#!/usr/bin/perl
use strict;
use warnings;

use include_common_modules;
use LWP::Simple;
use BOM::Database::AutoGenerated::Rose::MyaffiliatesTokenDetail;
use BOM::Utility::Log4perl;

BOM::Utility::Log4perl::init_log4perl_console;

system_initialize();

my $connection_builder = BOM::Platform::Data::Persistence::ConnectionBuilder->new({
    broker_code => 'FOG',
    operation   => 'write_collector',
});

my $sth = $connection_builder->db->dbh->prepare(
    q{
    WITH all_tokens AS (
        SELECT
            distinct(t.myaffiliates_token) as myaffiliates_token
        FROM
            betonmarkets.production_servers() srv,

            LATERAL dblink(srv.srvname,
            $$
                SELECT * FROM
                (
                    SELECT myaffiliates_token FROM betonmarkets.client
                    UNION
                    SELECT myaffiliates_token FROM betonmarkets.client_affiliate_exposure
                ) t
            $$
            ) AS t(myaffiliates_token VARCHAR)
    )
    SELECT
        myaffiliates_token
    FROM
        all_tokens t
    WHERE
        NOT EXISTS (SELECT 1 FROM data_collection.myaffiliates_token_details WHERE token = t.myaffiliates_token)
});
$sth->execute;

my $i = 0;
while (my $row = $sth->fetchrow_hashref) {
    my $token = $row->{myaffiliates_token};

    if (not $token) { next }
    my $content;
    eval {
        print $token;
        my $affiliate_record = BOM::Database::AutoGenerated::Rose::MyaffiliatesTokenDetail->new(
            db    => $connection_builder->db,
            token => $token,
        );

        if (
            $affiliate_record->load(
                speculative => 1,
            ))
        {
            print ++$i, "already in db\n";
            next;
        }
        print "Start to fetch token info [$token]:";
        $content = LWP::Simple::get('http://kavehmz:kv56eh3@admin.betonmarkets.com/feeds.php?FEED_ID=4&TOKENS=' . $token);
        die "Couldn't get token!" unless defined $content;
        print "Parsing the content:\n";
        my $affiliate = XML::Simple::XMLin($content);

        $affiliate_record->user_id($affiliate->{'TOKEN'}->{'USER_ID'});
        $affiliate_record->username($affiliate->{'TOKEN'}->{'USER'}->{'USERNAME'});
        $affiliate_record->status($affiliate->{'TOKEN'}->{'USER'}->{'STATUS'});
        $affiliate_record->email($affiliate->{'TOKEN'}->{'USER'}->{'EMAIL'});
        if ($affiliate->{'TOKEN'}->{'USER_ID'}) {
            print "Start to fetch myaffiliate [", $affiliate->{'TOKEN'}->{'USER_ID'}, "]\n";
            $content =
                LWP::Simple::get('http://kavehmz:kv56eh3@admin.betonmarkets.com/feeds.php?FEED_ID=1&USER_ID=' . $affiliate->{'TOKEN'}->{'USER_ID'});
            die "Couldn't get tags!" unless defined $content;
            print "Parsing the content:\n";
            my $user_tags   = '';
            my $parsed_tags = XML::Simple::XMLin($content)->{USER}->{USER_TAGS}->{TAG};
            if (ref $parsed_tags eq 'ARRAY') {
                foreach my $tag (@{$parsed_tags}) {
                    $user_tags .= ',' . $tag->{TAG_NAME};
                }
            } else {
                $user_tags = $parsed_tags->{TAG_NAME};
            }
            $affiliate_record->tags($user_tags);

            $affiliate_record->save();
        } else {
            print "Ignoring the affiliate, because its ID is empty [$content]\n";
            next;
        }
    };
    if ($@) {
        print STDERR "Error: [$@]: in parsing token[$token] from  [$content]\n";
    }

    print ++$i . " Done\n";

}
