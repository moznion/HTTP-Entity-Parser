package HTTP::Entity::Parser;

use 5.008005;
use strict;
use warnings;
use Stream::Buffered;
use HTTP::Entity::Parser::OctetStream;
use Module::Load;

our $VERSION = "0.01";

sub new {
    my $class = shift;
    bless { handlers => [] }, $class;
}

sub register {
    my ($self, $content_type, $klass, $opts) = @_;
    load $klass;
    push @{$self->{handlers}}, [$content_type, $klass, $opts];
}

sub get_parser {
    my ($self, $env) = @_;

    if (defined $env->{CONTENT_TYPE}) {
        for my $handler (@{$self->{handlers}}) {
            if (index($env->{CONTENT_TYPE}, $handler->[0]) == 0) {
                return $handler->[1]->new($env, $handler->[2]);
            }
        }
    }
    return HTTP::Entity::Parser::OctetStream->new();
}

sub parse {
    my ($self, $env) = @_;

    my $parser = $self->get_parser($env);

    my $ct = $env->{CONTENT_TYPE};
    if (!$ct) {
        # No Content-Type
        return ([], []);
    }

    my $input = $env->{'psgi.input'};

    my $buffer;
    if ($env->{'psgix.input.buffered'}) {
        # Just in case if input is read by middleware/apps beforehand
        $input->seek(0, 0);
    } else {
        $buffer = Stream::Buffered->new();
    }

    my $chunked = do { no warnings; lc delete $env->{HTTP_TRANSFER_ENCODING} eq 'chunked' };
    if ( my $cl = $env->{CONTENT_LENGTH} ) {
        my $spin = 0;
        while ($cl > 0) {
            $input->read(my $chunk, $cl < 8192 ? $cl : 8192);
            my $read = length $chunk;
            $cl -= $read;
            $parser->add($chunk);
            $buffer->print($chunk) if $buffer;
            
            if ($read == 0 && $spin++ > 2000) {
                Carp::croak "Bad Content-Length: maybe client disconnect? ($cl bytes remaining)";
            }
        }
    }
    elsif ($chunked) {
        my $chunk_buffer = '';
        my $length;
        DECHUNK: while(1) {
            $input->read(my $chunk, 8192);
            $chunk_buffer .= $chunk;
            while ( $chunk_buffer =~ s/^(([0-9a-fA-F]+).*\015\012)// ) {
                my $trailer   = $1;
                my $chunk_len = hex $2;
                if ($chunk_len == 0) {
                    last DECHUNK;
                } elsif (length $chunk_buffer < $chunk_len + 2) {
                    $chunk_buffer = $trailer . $chunk_buffer;
                    last;
                }
                my $loaded = substr $chunk_buffer, 0, $chunk_len, '';
                $parser->add($loaded);
                $buffer->print($loaded);
                $chunk_buffer =~ s/^\015\012//;
                $length += $chunk_len;                        
            }
        }
        $env->{CONTENT_LENGTH} = $length;
    }

    if ($buffer) {
        $env->{'psgix.input.buffered'} = 1;
        $env->{'psgi.input'} = $buffer->rewind;
    } else {
        $input->seek(0, 0);
    }

    $parser->finalize();
}

1;
__END__

=encoding utf-8

=head1 NAME

HTTP::Entity::Parser - PSGI compliant HTTP Entity Parser

=head1 SYNOPSIS

    use HTTP::Entity::Parser;
    
    my $parser = HTTP::Entity::Parser->new;
    $parser->register('application/x-www-form-urlencoded','HTTP::Entity::Parser::UrlEncoded');
    $parser->register('multipart/form-data','HTTP::Entity::Parser::MultiPart');
    $parser->register('application/json','HTTP::Entity::Parser::JSON');

    sub app {
        my $env = shift;
        my ( $params, $uploads) = $parser->parse($env);
    }

=head1 DESCRIPTION

HTTP::Entity::Parser is PSGI compliant HTTP Entity parser. This module also has compatibility 
with L<HTTP::Body>. Unlike HTTP::Body, HTTP::Entity::Parser reads HTTP entity from 
PSGI's env C<$env->{'psgi.input'}> and parse it.
This module support application/x-www-form-urlencoded, multipart/form-data and application/json.


=head1 METHODS

=over 4

=item new()

Create the instance.

=item register($content_type:String, $class:String, $opts:HashRef)

Register parser class.

  $parser->register('application/x-www-form-urlencoded','HTTP::Entity::Parser::UrlEncoded');
  $parser->register('multipart/form-data','HTTP::Entity::Parser::MultiPart');
  $parser->register('application/json','HTTP::Entity::Parser::JSON');

If the request content_type match registered type, HTTP::Entity::Parser uses registered 
parser class. If content_type does not match any registered type, HTTP::Entity::Parser::OctetStream is used.

=item parse($env:HashRef)

parse HTTP entity from PSGI's env.

  my ( $params:ArrayRef, $uploads:ArrayRef) = $parser->parse($env);

C<$param> is key-value pair list.

   my ( $params, $uploads) = $parser->parse($env);
   my $body_parameters = Hash::MultiValue->new(@$params);

C<$uploads> is ArrayRef of HashRef.

   my ( $params, $uploads) = $parser->parse($env);
   warn Dumper($uploads->[0]);
   {
       "name" => "upload", #field name
       "headeres" => [
           "Content-Type" => "application/octet-stream",
           "Content-Disposition" => "form-data; name=\"upload\"; filename=\"hello.pl\""           
       ],
       "size" => 78, #size of upload content
       "filename" => "hello.png", #original filename in the client
       "tempname" => "/tmp/XXXXX", # path to the temporary file where uploaded file is saved
   }

use with Plack::Request::Upload

   my ( $params, $uploads) = $parser->parse($env);
   my $upload = Hash::MultiValue->new();
   for my $obj ( @$uploads ) {
       my %copy = %$obj;
       $copy{headers} = HTTP::Headers->new(%{$obj->{headers}});
       $upload->add($$copy->{name}, Plack::Request::Upload->new(%copy));
   }

=back

=head1 PARSERS

=over 4

=item OctetStream

Default parser, This parser does not parse entity, always return empty list. 

=item UrlEncoded

For C<application/x-www-form-urlencoded>. It is used for HTTP POST without file upload

=item MultiPart

For C<multipart/form-data>. It is used for HTTP POST contains file upload.

MultiPart parser use L<HTTP::MultiPartParser>.

=item JSON

For C<application/json>. This parser decode JSON body automatically. 

It is convenient to use with Ajax form.

=back

=head1 WHAT'S DIFFERENT FROM HTTP::Body

HTTP::Entity::Parser accept PSGI's env and read body from it.

HTTP::Entity::Parser is able to choose parsers by the instance, HTTP::Body requires to modify global variables.

=head1 SEE ALSO

=over 4

=item L<HTTP::Body>

=item L<HTTP::MultiPartParser>.

=item L<Plack::Request>

=back

=head1 LICENSE

Copyright (C) Masahiro Nagano.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Masahiro Nagano E<lt>kazeburo@gmail.comE<gt>

Tokuhiro Matsuno E<lt>tokuhirom@gmail.comE<gt>

This module is based on tokuhirom's code, see L<https://github.com/plack/Plack/pull/434>

=cut

