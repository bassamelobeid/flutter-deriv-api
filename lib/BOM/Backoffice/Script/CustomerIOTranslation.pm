package BOM::Backoffice::Script::CustomerIOTranslation;

use strict;
use warnings;
use HTTP::Tiny;
use List::Util qw(first any none reduce sum);
use HTML::TreeBuilder;
use Digest::SHA1           qw(sha1_hex);
use BOM::Platform::Context qw(localize request);
use BOM::Platform::Context::Request;
use BOM::Config;
use Encode qw(encode_utf8);
use Text::Trim;
use Syntax::Keyword::Try;
use JSON::MaybeUTF8 qw(:v1);
use Log::Any        qw($log);
use Time::HiRes;

use constant {
    API_URL     => 'https://beta-api.customer.io/v1/api/',
    REQ_PER_SEC => 10,
};

my %rate_limit;

=head2 new

Constructor.

=cut

sub new {
    my ($class, %args) = @_;

    return bless {token => $args{token}}, $class;
}

=head2 update_campaigns_and_snippets

Main entry point to update campaign emails and snippets
Only campaigns with valid actions are returned.
If $filter_campaign is not provided, campaign will not be
updated unless it has 'ready' tag and no 'testing' tag.

=cut

sub update_campaigns_and_snippets {
    my ($self, $filter_campaign) = @_;

    $log->debugf('will process emails/PNs and snippets for campaign: %s', $filter_campaign ? $filter_campaign : 'all');

    my $campaigns     = $self->get_campaigns($filter_campaign);
    my $current_snips = $self->get_snippets;
    my @snips_to_keep;

    CAMPAIGN:
    for my $campaign (@$campaigns) {

        my @campaign_snips = ($campaign->{live}{subject} . $campaign->{live}{body}) =~ /\{\{snippets\.(\w+?)\}\}/gm;

        my $result = $self->process_camapign($campaign);

        if (not $campaign->{updateable}) {
            $log->debugf("skipping update of campaign '%s' due to tags", $campaign->{name});
            push @snips_to_keep, @campaign_snips;
            next CAMPAIGN;
        }

        my %strings_by_id = map { $_->{id} => $_ } $result->{strings}->@*;

        for my $id (keys %strings_by_id) {
            my $string   = $strings_by_id{$id};
            my $new_snip = $self->generate_snippet($string, $campaign->{name});
            next if exists $current_snips->{$id} and $current_snips->{$id} eq $new_snip;

            $log->debugf("updating snippet %s for string '%s'", $id, $string->{orig_text});
            unless ($self->update_snippet($id, $new_snip)) {
                $log->warnf("Skipping campaign '%s' because we could not update a snippet:\n%s", $campaign->{name}, $new_snip);
                push @snips_to_keep, @campaign_snips;
                next CAMPAIGN;
            }
        }

        if ($result->{body} ne $campaign->{live}{body} or $result->{subject} ne $campaign->{live}{subject}) {
            $log->debugf("updating 'send automatically' action of campaign '%s'", $campaign->{name});

            if ($self->update_campaign_action($campaign, $result->{body}, $result->{subject})) {
                @campaign_snips = map { $_->{id} } $result->{strings}->@*;
            }
        } else {
            $log->debugf("campaign '%s' is unchanged", $campaign->{name});
        }

        push @snips_to_keep, @campaign_snips;
    }

    # Delete all snippets, but:
    #   - snippets in use (@snips_to_keep)
    #   - snippets with 'custom_' prefix
    unless ($filter_campaign) {
        my %used_snips = map { $_ => 1 } @snips_to_keep;
        for my $snip (grep { (not exists $used_snips{$_}) && $_ !~ m/^custom_/ } keys %$current_snips) {
            $log->debugf("deleting unused snippet %s", $snip);
            $self->delete_snippet($snip);
        }
    }
}

=head2 http

HTTP::Tiny client.

=cut

sub http {
    my $self = shift;
    return $self->{http} //= HTTP::Tiny->new(default_headers => {Authorization => 'Bearer ' . $self->{token}});
}

=head2 languages

All supported languages.

=cut

sub languages { shift->{languages} //= BOM::Config::Runtime->instance->app_config->cgi->supported_languages }

=head2 call_api

Call Customer.io API.

=cut

sub call_api {
    my ($self, $method, $endpoint, $content) = @_;

    # Customer IO Beta API rate limit is 10 requests per second
    my $ts = sprintf('%.1f', Time::HiRes::time);
    $rate_limit{$ts}++;
    delete @rate_limit{grep { $_ <= $ts - 1 } keys %rate_limit};
    if (sum(values %rate_limit) > REQ_PER_SEC) {
        $log->debugf('Sleeping for 1 sec to avoid rate limit');
        sleep 1;
    }

    my @args = ($method, API_URL . $endpoint);
    push(@args, {content => encode_json_utf8($content)}) if $content;

    my $res = $self->http->request(@args);
    die "$res->{content}\n" unless $res->{success};

    return defined($res->{headers}{'content-type'}) && $res->{headers}{'content-type'} =~ /application\/json/ ? decode_json_utf8($res->{content}) : 1;
}

=head2 get_campaigns

Get valid campaigns from Customer.io.
Only processable campaigns are returned:
There must one email with 'off' sending_state and one with 'automatic'.

=cut

sub get_campaigns {
    my ($self, $filter_campaign) = @_;

    my ($campaigns, $broadcasts);
    try {
        $campaigns  = $self->call_api('GET', 'campaigns')->{campaigns};
        $broadcasts = $self->call_api('GET', 'broadcasts')->{broadcasts};
    } catch ($e) {
        $log->errorf('Failed to get campaigns: %s', $e);
        return undef;
    }

    my @result;
    for my $campaign (@$campaigns, @$broadcasts) {
        my $name = $campaign->{name};

        next if $filter_campaign and $name ne $filter_campaign;
        next unless $campaign->{actions}->@* == 2;

        my $actions  = $self->get_actions($campaign) or next;
        my $template = first { ($_->{sending_state} // '') eq 'off' } @$actions;
        my $live     = first { ($_->{sending_state} // '') eq 'automatic' } @$actions;
        next unless $live and $template;

        if ($template->{type} ne $live->{type} or $template->{type} !~ /^(email|push)$/) {
            $log->errorf("Campaigns '%s' actions are invalid", $name);
            next;
        }

        my @tags       = ($campaign->{tags} // [])->@*;
        my $updateable = (any { lc($_) eq 'ready' } @tags) && !(any { lc($_) eq 'testing' } @tags);

        push @result,
            {
            name       => $name,
            id         => $campaign->{id},
            type       => $campaign->{type},
            template   => $template,
            live       => $live,
            updateable => (
                       $filter_campaign
                    or $updateable ? 1 : 0
            ),
            };
    }

    return \@result;
}

=head2 get_actions

Gets all campaign actions from Customer.io.

=cut

sub get_actions {
    my ($self, $campaign) = @_;

    my $url = join '/', $campaign->{type} eq 'triggered_broadcast' ? 'broadcasts' : 'campaigns', $campaign->{id}, 'actions';

    try {
        return $self->call_api('GET', $url)->{actions};
    } catch ($e) {
        $log->errorf('Failed to get campaign actions: %s', $e);
        return undef;
    }
}

=head2 get_snippets

Returns hashref of all current snippets in Customer.io.

=cut

sub get_snippets {
    my ($self) = @_;

    try {
        my $snippets = $self->call_api('GET', 'snippets')->{snippets};
        return {map { $_->{name} => $_->{value} } @$snippets};
    } catch ($e) {
        $log->errorf('Failed to get snippets: %s', $e);
        return undef;
    }
}

=head2 update_snippet

Update single snippet in Customer.io.

=cut

sub update_snippet {
    my ($self, $id, $snip) = @_;

    try {
        return $self->call_api(
            'PUT',
            'snippets',
            {
                name  => $id,
                value => $snip
            });
    } catch ($e) {
        $log->warnf('Failed to update snippet %s: %s', $id, $e);
        return undef;
    }
}

=head2 delete_snippet

Delete single snippet in Customer.io.

=cut

sub delete_snippet {
    my ($self, $id) = @_;

    try {
        return $self->call_api('DELETE', 'snippets/' . $id);
    } catch ($e) {
        $log->warnf('Failed to delete snippet %s: %s', $id, $e);
        return undef;
    }
}

=head2 update_campaign_action

Updates the 'live' action of a campaign in Customer.io.

=cut

sub update_campaign_action {
    my ($self, $campaign, $body, $subject) = @_;

    my $url = join '/', $campaign->{type} eq 'triggered_broadcast' ? 'broadcasts' : 'campaigns', $campaign->{id}, 'actions', $campaign->{live}{id};

    try {
        return $self->call_api(
            'PUT', $url,
            {
                body    => $body,
                subject => $subject
            });
    } catch ($e) {
        $log->errorf('Failed to update campaign action: %s', $e);
        return undef;
    }
}

=head2 process_camapign

Extract all strings from campaign template and insert snippet IDs in HTML.

Returns a hashref with keys:
    
=over 4

=item * body: html with snippet ids inserted

=item * strings: array of string items

=back

=cut

sub process_camapign {
    my ($self, $campaign) = @_;

    my $template = $campaign->{template};
    my $type     = $template->{type};
    my $body     = $template->{body};
    $body = $template->{layout} if $template->{layout} =~ s/\{\{content\}\}/$body/m;
    my $result;

    if ($type eq 'email') {
        $result = process_email_body($body);
    } elsif ($type eq 'push') {
        $result = {
            body    => $body,
            strings => []};
        if (is_localizable($body)) {
            my $item = process_text($body);
            $result = {
                body    => snippet_tag($item),
                strings => [$item]};
        }
    }

    my $subject = $template->{subject};
    if (is_localizable($subject)) {
        my $item = process_text($subject);
        $subject = snippet_tag($item);
        push $result->{strings}->@*, $item;
    }
    $result->{subject} = $subject;

    return $result;
}

=head2 process_email_body

Process the html body of an email.

Returns a hashref with keys:
    
=over 4

=item * body: html with snippet ids inserted

=item * strings: array of string items

=back

=cut

sub process_email_body {
    my $body = shift;

    # first handle our special <loc> tags
    my $replaced_res = process_loc_tags($body);
    my @strings      = $replaced_res->{strings}->@*;

    my $tree = HTML::TreeBuilder->new;
    $tree->store_comments(1);
    $tree->implicit_tags(0);
    # HTML::TreeBuilder will add <div> if there is no root node, so we add one
    $tree->parse('<div>' . $replaced_res->{text} . '</div>');
    $tree->eof;

    my $root = $tree->guts;                # discard head, meta etc.
    push @strings, process_node($root);    # recursively process html structure

    my $output = $root->as_HTML('<>&', "\t", {});
    $output =~ s/^<div>(.*?)<\/div>$/$1/s;    # remove the <div>

    return {
        body    => trim($output),
        strings => \@strings
    };
}

=head2 process_loc_tags

Process our special <loc>...</loc> tags used for manual localization.

Returns a hashref with keys:
    
=over 4

=item * text: text with snippet ids inserted

=item * strings: array of string items

=back

=cut

sub process_loc_tags {
    my $text = shift;

    my @strings;

    my $re_sub = sub {
        my $string = shift;
        return $string unless is_localizable($string);
        my $item = process_text($string);
        push @strings, $item;
        return snippet_tag($item);
    };

    $text =~ s/<loc>([^>]*)<\/loc>/$re_sub->($1)/gme;
    return {
        text    => $text,
        strings => \@strings
    };
}

=head2 process_node

Process a single HTML node, will recurse into children.

Returns array of string items.
Modifies $node in place.

=cut

sub process_node {
    my $node = shift;
    return if is_ignorable($node);

    my @result;
    my @elts = $node->content_list;

    # If element contains localizable text and no block elements
    if ((any { not ref($_) and is_localizable($_) } @elts) and none { is_block($_) } @elts) {
        my $text = reduce { (ref($a) ? $a->as_HTML('<>&') : $a) . (ref($b) ? $b->as_HTML('<>&') : $b) } $node->detach_content;
        my $item = process_text($text);
        push @result, $item;
        $node->push_content(snippet_tag($item));
    } else {
        for (my $i = 0; $i < @elts; $i++) {
            my $elt = $elts[$i];
            if (ref $elt) {
                # block element
                push @result, process_node($elt);
            } elsif (is_localizable($elt)) {
                # text on the same level as block elements
                my $item = process_text($elt);
                push @result, $item;
                $node->splice_content($i, 1, snippet_tag($item));
            }
        }
    }
    return @result;
}

=head2 is_block

Returns true if the node is block element that cannot appear inline in text.

=cut

sub is_block {
    my $node = shift;
    return (ref($node)
            and any { $node->tag eq $_ }
            qw(address article aside blockquote canvas dd div dl dt fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hr li main nav noscript ol p pre section table td tfoot tr ul video)
    );
}

=head2 is_ignorable

Returns true for nodes that we never include for localization.

=cut

sub is_ignorable {
    my $node = shift;
    return (ref($node) and any { $node->tag eq $_ } qw(style ~comment));
}

=head2 is_localizable

Returns true if the text should be localized.

=cut

sub is_localizable {
    my $text = shift;
    $text =~ s/\{\{[^{]+\}|\{%.+?%\}//gm;
    return $text =~ /\p{L}/;
}

=head2 snippet_tag

Create a Customer IO tag to reference a snippet.

=cut

sub snippet_tag {
    '{{snippets.' . shift->{id} . '}}';
}

=head2 process_text

Convert HTML tags and Customer IO placeholders to localizable placeholders.

=cut

sub process_text {
    my $orig_text = trim(shift);

    my ($i, @placeholders);

    my $re_sub = sub {
        push @placeholders, shift;

        return '[_' . ++$i . ']';
    };

    my $loc_text = $orig_text =~ s/[~\[\]]/~$&/gr;    # escape square brackets, see https://metacpan.org/pod/Locale::Maketext#BRACKET-NOTATION
    $loc_text =~ s/(\{\{[^}]*\}\}|<[^>]*>|\{%.+?%\})/$re_sub->($1)/gme;

    return {
        orig_text    => $orig_text,
        loc_text     => $loc_text,
        placeholders => \@placeholders,
        id           => sha1_hex(encode_utf8($orig_text)),
    };
}

=head2 generate_snippet

Generates snippet content with all the possible translations.

=cut

sub generate_snippet {
    my ($self, $string, $campaign_name) = @_;

    my $req = BOM::Platform::Context::Request->new(language => 'EN');
    request($req);

    my $en_text;
    try {
        $en_text = localize($string->{loc_text}, $string->{placeholders}->@*);
    } catch ($e) {
        $log->warnf("Localize() failed for string '%s' in campaign '%s': %s", $string->{loc_text}, $campaign_name, $e);
        # we can assume it's going to fail for the other languages too
        return $string->{orig_text};
    }

    my %trans;

    for my $lang ($self->languages->@*) {
        next if $lang eq 'EN';

        my $req = BOM::Platform::Context::Request->new(language => $lang);
        request($req);

        my $tr = $string->{orig_text};
        try {
            $tr = localize($string->{loc_text}, $string->{placeholders}->@*);
        } catch ($e) {
            $log->warnf("Localize() failed for string '%s' in campaign '%s': %s", $string->{loc_text}, $campaign_name, $e);
        }

        # if translation missed
        next if $tr eq $en_text;
        $trans{$lang} = $tr;
    }

    return $en_text unless %trans;

    my @langs = sort keys %trans;

    my $lang = shift @langs;
    my $res  = qq[{% if event.lang == "$lang" %}\n$trans{$lang}\n];

    for my $lang (@langs) {
        $res .= qq[{% elsif event.lang == "$lang" %}\n$trans{$lang}\n];
    }

    $res .= qq[{% else %}\n$en_text\n{% endif %}];

    return $res;
}

1;
