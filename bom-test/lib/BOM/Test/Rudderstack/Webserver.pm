use Object::Pad;

=head1 Rudderstack_Webserver

 BOM::Test::Rudderstack::Webserver - Webservice mocking events sent to rudderstack.

=head1 SYNOPSIS

 use BOM::Test::Rudderstack::Webserver;

=head1 DESCRIPTION

 This module listents to requests outbound form bom-events to rudderstack via track_event call.
 It validates then logs the event detials in an html file.

=cut

class BOM::Test::Rudderstack::Webserver :isa(IO::Async::Notifier);

use Future::AsyncAwait;
use Syntax::Keyword::Try;
use Net::Async::HTTP::Server;
use HTTP::Response;
use JSON::MaybeUTF8 qw(:v1);
use Unicode::UTF8;
use Scalar::Util qw(refaddr blessed);
use curry;
use Carp  qw(croak);
use POSIX qw/strftime/;

use Log::Any qw($log);
use constant HTML_HEAD =>
    "<!DOCTYPE html><table role=\"presentation\" width=\"800\" align=\"center\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\"> <tr><td width=\"100%\" style=\"font-family:Arial, sans-serif; font-size:16px; line-height:1.5em; color:#333333; padding:2em; background-color:#e4e4e4;\">";
use constant HTML_FOOT => "</td></tr></table>";
use constant PATH      => "/usr/share/nginx/html/events/";

field $port;
field $server;

=head2 configure_unknown

 Sets a port for the webserver to listen on.

=cut

method configure_unknown (%args) {
    $port   = $args{port};
    $server = $args{server};
    delete $args{$_} foreach qw/port server/;

    return unless keys %args;
    my $class = ref $self;
    croak "Unrecognised configuration keys for $class - " . join(" ", keys %args);
}

=head2 _add_to_loop

 Adds an HTTP::Server to the loop.

=cut

method _add_to_loop {
    $self->add_child(
        # Server
        $server = Net::Async::HTTP::Server->new(
            on_request => $self->curry::weak::handle,
        ));
}

=head2 handle

 Handles incoming requests.

=cut

async method handle {
    (undef, my $req) = @_;
    $log->infof('HTTP receives %s %s:%s', $req->method, $req->path, $req->body);
    try {
        my $body_params = decode_json_utf8($req->body || '{}');
        $self->validates($body_params) if ($req->path eq '/rudderstack/track');
        $self->record($body_params);
        $self->respond(
            $req,
            {
                code => 200,
                msg  => 'success'
            });
    } catch ($e) {
        $log->errorf('Failed while handling request - %s', $e);
        $self->fail($req, $e);
    }
}

=head2 validates

 Validates each request against expcted event attributes.

=cut

method validates ($body) {
    for my $attribute ('event', 'userId', 'sentAt', 'context', 'properties') {
        die {
            code => 400,
            msg  => "Expected attribute $attribute in request body"
        } unless defined $body->{$attribute};
    }
}

=head2 record

 Records each valid event in a html file.

=cut

method record ($body) {
    my $prefix   = strftime("%Y%m%d%R", localtime);
    my $suffix   = $body->{event} // 'Identify_Request';
    my $filename = PATH . "$prefix-Rudderstack_$suffix.html";
    open(my $fh, '>>', $filename) or die $log->error("Could not open file $filename  $!");
    print $fh HTML_HEAD;
    traverse($fh, $body);
    print $fh HTML_FOOT;
    close $fh;
}

=head2 respond

 Replies back to received request.

=cut

method respond ($req, $data) {
    my $response = HTTP::Response->new($data->{code});
    $response->add_content(encode_json_utf8([$data->{msg}]));
    $response->content_type("application/json");
    $response->content_length(length $response->content);
    $req->respond($response);
}

=head2 fail

 Records validation error in an html file and/or replies back to received request with code 400 and error message.

=cut

method fail ($req, $error) {
    if (ref($error) eq 'HASH') {
        my $body_params = decode_json_utf8($req->body || '{}');
        my $filename    = PATH . time . "-Rudderstack_error-" . ($body_params->{event} ? $body_params->{event} : $error->{code}) . ".html";
        open(my $fh, '>>', $filename) or die $log->error("Could not open file $filename  $!");
        print $fh HTML_HEAD;
        print $fh
            "<p style=\"font-family:Arial, sans-serif; font-size:20px; margin:0; color:#CD212A; padding:4em;\"> $error->{code}: $error->{msg} </p>";
        traverse($fh, $body_params);
        print $fh HTML_FOOT;
        close $fh;

        return $self->respond($req, $error);
    }
    return $self->respond(
        $req,
        {
            code => '400',
            msg  => $error // 'UNKNOWN'
        });
}

=head2 traverse

 Traverses through a hash to print its contents to a file handler.

=cut

sub traverse {
    my ($fh, $hash) = @_;
    my $rhash;
    for my $attribute (sort keys %$hash) {
        $rhash = $hash->{$attribute};
        if (ref $rhash eq 'HASH') {
            print $fh "<h3 style=\"margin:0;\">$attribute</h3>";
            traverse($fh, $rhash);
        } elsif ($attribute =~ m/url/) {
            print $fh
                "<p style=\"font-family:Arial, sans-serif; font-size:16px; margin:0;\"> $attribute: </p><a style=\"margin:0;\" href=\"$rhash\"> $rhash </a>";
        } else {
            print $fh "<p style=\"margin:0;\"> $attribute: $rhash </p>";
        }
    }
}

=head2 start

 Starts listing to the preset port for incoming requests.

=cut

async method start {
    my $listner = await $server->listen(
        addr => {
            family   => 'inet6',
            socktype => 'stream',
            port     => $port
        });
    my $port = $listner->read_handle->sockport;
    $log->infof('Listening on port %s', $port);
    return $port;
}

=head2 run

 The main run function of the rudderstack mocking webserver.

=cut

async method run() {
    $port = await $self->start();
    while (1) {
        $log->infof('Rudderstack mocking webservice is running');
        await $self->loop->run;
    }
}

1;
