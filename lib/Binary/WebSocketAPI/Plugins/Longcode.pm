package Binary::WebSocketAPI::Plugins::Longcode;

use strict;
use warnings;

use parent qw(Mojolicious::Plugin);

=head1 NAME

Binary::WebSocketAPI::Plugins::Longcode - provides longcode lookup support

=head1 DESCRIPTION

Provides a helper C<< $c->longcode >> which can be used to retrieve longcode
details for the given short code and currency.

See the L</longcode> documentation for details.

=cut

no indirect;
use Syntax::Keyword::Try;
use List::Util qw(shuffle);
use Cache::LRU;
use Future;
use Future::Utils qw(fmap0);
use Future::Mojo;

use Log::Any qw($log);

# Expecting ~250 bytes per value (arrayref with string and Future),
# ~100 bytes per key, so this should add about 25MB total to process size
use constant CACHE_ENTRIES => 20_000;

# Any more than this and we're in big trouble
use constant MAX_QUEUED_ITEMS_PER_KEY => 10_000;

# How many items we can comfortably handle in a single request
use constant SHORTCODES_PER_BATCH => 50;

# Number of active RPC calls across the entire process
use constant CONCURRENT_REQUESTS => 4;

# Number of seconds we'll allow for the RPC and cache update steps.
# It should be a very fast call, please don't set this too high -
# anything more than 5 seconds is probably a bad idea.
use constant RPC_TIMEOUT => 5;

# This caches longcode strings based on L</memory_cache_key>, which consists of currency, language and shortcode
my $longcode_cache = Cache::LRU->new(size => CACHE_ENTRIES);
# This tracks the pending longcode requests as a 2-level hash - first level is L</pending_request_key>, second level
# is shortcode, and the leaf values are L<Future> instances which resolve with the relevant longcode on completion.
my %pending_short_codes_by_currency_and_language;

=head1 METHODS

=cut

=head2 memory_cache_key

Takes C<currency>, C<language> and C<short_code> as parameters, and returns an
opaque key (Unicode string) for cache lookups.

=cut

sub memory_cache_key {
    my ($self, $currency_code, $language, $short_code) = @_;
    return join "\0", $currency_code, $language, $short_code;
}

=head2 pending_request_key

Takes C<currency> and C<language> as parameters, and returns an opaque key
(Unicode string) for identifying entries in the top level of
C<< %pending_short_codes_by_currency_and_language >>.

=cut

sub pending_request_key {
    my ($self, $currency_code, $language) = @_;
    return join "\0", $currency_code, $language;
}

=head2 longcode

Given a short_code and currency, will return a L<Future> which resolves
to the localised long code for that contract.

Example:

    $c->longcode($short_code, $payload->{currency})->on_done(sub {
        warn "Longcode was " . shift . " for $short_code\n";
    });

=cut

sub longcode {
    my ($self, $c, $short_code, $currency_code) = @_;
    my $language = $c->stash('language') // die 'need a language';
    die 'no currency'  unless $currency_code;
    die 'no shortcode' unless $short_code;

    # Return cached value immediately
    if (my $longcode = $longcode_cache->get($self->memory_cache_key($currency_code, $language, $short_code))) {
        $log->tracef("Cached value for %s is %s", $short_code, $longcode);
        return Future->done($longcode);
    }
    my $req_key = $self->pending_request_key($currency_code, $language);
    $log->tracef("Will look for currency code %s, language %s shortcode %s", $currency_code, $language, $short_code);
    my $f = ($pending_short_codes_by_currency_and_language{$req_key}{$short_code} ||= Future::Mojo->new);
    $self->trigger_longcode_lookup($c);
    return $f->retain;
}

=head2 trigger_longcode_lookup

Starts a longcode lookup, if not already active.

=cut

sub trigger_longcode_lookup {
    my ($self, $c) = @_;
    return $self->{longcode_lookup} ||= (
        fmap0 {
            # Allow a few seconds for the lookup.
            return Future->needs_any($self->process_next_batch($c), Future::Mojo->new_timer(RPC_TIMEOUT));
        }
        concurrent => CONCURRENT_REQUESTS,
        generate   => sub { keys(%pending_short_codes_by_currency_and_language) ? 1 : () }
    )->on_ready(
        sub {
            $log->tracef("Done, clearing longcode_lookup key");
            delete $self->{longcode_lookup};
        });
}

=head2 process_next_batch

Do an RPC lookup with the next appropriate set of items from the pending list.

Takes a Mojolicious app context and returns a L<Future>.

=cut

sub process_next_batch {
    my ($self, $c) = @_;

    # Pick one currency+language key using a uniform distribution
    my @keys = keys %pending_short_codes_by_currency_and_language;
    $log->tracef("Starting longcode lookup, we have %d keys to work with", 0 + @keys);
    my $k = $keys[rand @keys];

    my $pending = $pending_short_codes_by_currency_and_language{$k};
    my ($currency, $language) = split /\0/, $k;
    $log->tracef("Currency %s, language %s", $currency, $language);
    unless (keys %$pending) {
        # This should not be possible, so we warn.
        warn "Had no short_codes to look up for currency $currency language $language";
        return Future->done;
    }

    # We'd like to avoid one client/app_id monopolising the service
    my @items       = shuffle keys %$pending;
    my @short_codes = splice @items, 0, SHORTCODES_PER_BATCH;
    my @f           = delete @{$pending}{@short_codes};
    $log->tracef("Have %d items with %d remaining", 0 + @short_codes, 0 + @items);

    # If things go badly wrong and we have an excessive backlog, let's limit things
    if (@items > MAX_QUEUED_ITEMS_PER_KEY) {
        warn "Have way too many short_codes in the lookup queue (" . @items . "), panic is advised";
        my @excess = splice @items, MAX_QUEUED_ITEMS_PER_KEY;
        $_->fail('System is overloaded, please try later', longcode => 0 + @items) for delete @{$pending}{@excess};
    }

    # Discarding the key here should prevent us from hitting empty slots
    delete $pending_short_codes_by_currency_and_language{$k} unless keys %$pending;

    $log->tracef("Calling RPC");
    my $rpc_completion = Future::Mojo->new;
    $c->call_rpc({
            args        => {},
            msg_type    => '',
            method      => 'longcode',
            call_params => {
                short_codes => [@short_codes],
                currency    => $currency,
                language    => $language,
            },
            block_response => 1,
            rpc_failure_cb => sub {
                my (undef, undef, undef, $err) = @_;
                $log->warnf("Error happened when fetch longcode: %s", $err);
            },
            response => sub {
                my $rpc_response = shift;
                $log->tracef("RPC responds with %s", $rpc_response);
                if (my $longcodes = $rpc_response->{longcodes}) {
                    for my $short_code (keys %$longcodes) {
                        $longcode_cache->set($self->memory_cache_key($currency, $language, $short_code) => $longcodes->{$short_code})
                            if $longcodes->{$short_code};
                    }
                    # Note that any of the Future callbacks could potentially raise exceptions,
                    # so we mark those as complete in a separate loop.
                    for my $idx (0 .. $#f) {
                        try {
                            $f[$idx]->done($longcodes->{$short_codes[$idx]}) unless $f[$idx]->is_ready;
                        } catch {
                            warn "Had exception while processing index item $idx, shortcode was "
                                . $short_codes[$idx]
                                . " and longcode "
                                . $longcodes->{$short_codes[$idx]}
                                . ", exception: $_\n";
                        }
                    }
                }
                $rpc_completion->done;
                return;
            },
        });
    return $rpc_completion;
}

sub register {
    my ($self, $app) = @_;
    $app->helper(
        longcode => $self->curry::longcode,
    );
    return;
}

1;

