package BOM::API::Payment::Role::Plack;

## no critic (RequireUseStrict,RequireUseWarnings)

use Moo::Role;
use Plack::Request;
use Scalar::Util qw( looks_like_number );
use XML::Simple;
use DataDog::DogStatsd::Helper qw(stats_inc);

has 'env' => (
    is       => 'ro',
    required => 1
);
has 'req' => (is => 'lazy');

sub _build_req {
    return Plack::Request->new((shift)->env);
}

# alias
sub request { return (shift)->req }

has 'user' => (is => 'lazy');

sub _build_user {
    return (shift)->env->{BOM_USER};
}

has 'request_parameters' => (
    is => 'lazy',
);

sub _build_request_parameters {
    my $c = shift;

    my $content_type = $c->req->header('Content-Type');
    my $params       = $c->req->parameters;

    if (keys %{$params}) {
        return $params;
    } elsif ($content_type and $content_type =~ 'xml') {
        my $xs = XML::Simple->new(ForceArray => 0);
        if ($c->req->content) {
            return $xs->XMLin($c->req->content);
        }
    }

    return {};
}

## Response
sub throw {
    my $c       = shift;
    my $log     = $c->env->{log};
    my $status  = shift || 500;
    my $message = shift || do {
        $log->error("Raising Status $status, no message");
        return {status_code => $status};
    };
    chomp($message);
    $log->info(sprintf '%s: %s', ($c->user && $c->user->loginid) || '(no-user)', $message);
    return {
        status_code => $status,
        error       => $message
    };
}

sub status_bad_request {
    my ($c, $message, $datadog_metric) = @_;
    my $log = $c->env->{log};
    chomp($message);
    my $log_message = sprintf '%s: %s', ($c->user && $c->user->loginid) || '(no-user)', $message;
    if ($datadog_metric) {
        DataDog::DogStatsd::Helper::stats_inc($datadog_metric);
    }
    $log->info($log_message);

    return {
        status_code => 400,
        error       => $message
    };
}

sub status_created {
    my ($c, $location) = @_;

    return $c->req->new_response(201, [Location => $location]);
}

## Validator
sub validate {
    my ($c, @required_fields) = @_;

    foreach my $f (@required_fields) {
        return "$f is required." unless defined $c->request_parameters->{$f};
    }

    if (my $currency_code = $c->request_parameters->{'currency_code'}) {
        my @currencies = qw(AUD EUR GBP USD JPY);
        my $regex      = '(' . join('|', @currencies) . ')';
        return "Invalid currency $currency_code. Must be one of: " . join(', ', @currencies)
            unless $currency_code =~ /^$regex$/;
    }

    foreach my $f ('trace_id', 'reference_number') {
        next unless my $v = $c->request_parameters->{$f};
        return "$f must be a positive integer." unless $v =~ /^\d+$/ and $v > 0;
    }

    foreach my $f ('amount', 'bonus', 'fee') {
        next unless defined(my $v = $c->request_parameters->{$f});
        return "Invalid money amount: $v" unless looks_like_number($v);
        return "Invalid money amount: $v" if $v =~ /\.\d{3}/ or $v =~ /\.$/;

        # extra validate for amount
        if ($f eq 'amount') {
            return "Invalid money amount: $v" unless $v >= 0.01 and $v <= 100000;
        }
    }

    return;
}

no Moo::Role;
1;
