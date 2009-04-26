package POE::Component::Win32::Service;

# Author: Chris "BinGOs" Williams
#
# This module may be used, modified, and distributed under the same
# terms as Perl itself. Please see the license that came with your Perl
# distribution for details.
#

use POE 0.31;
use POE::Wheel::Run;
use POE::Filter::Line;
use POE::Filter::Reference;
use Win32;
use Win32::Service qw(StartService StopService GetStatus PauseService ResumeService GetServices);
use Carp qw(carp croak);
use vars qw($VERSION);

$VERSION = '0.50';

our %cmd_map = ( qw(start StartService stop StopService restart RestartService status GetStatus pause PauseService resume ResumeService services GetServices) );


sub spawn {
  my ($package) = shift;
  croak "$type needs an even number of parameters" if @_ & 1;
  my %params = @_;

  foreach my $param ( keys %params ) {
     $params{ lc $param } = delete ( $params{ $param } );
  }

  my $options = delete ( $params{'options'} );

  my $self = bless \%params, $package;

  $self->{session_id} = POE::Session->create(
	  object_states => [
	  	$self => { 'start'    => 'request',
			   'stop'     => 'request',
			   'restart'  => 'request',
			   'status'   => 'request',
			   'pause'    => 'request',
			   'resume'   => 'request',
			   'services' => 'request',
		},
	  	$self => [ qw(_start shutdown wheel_close wheel_err wheel_out wheel_stderr) ],
	  ],
	  ( ( defined ( $options ) and ref ( $options ) eq 'HASH' ) ? ( options => $options ) : () ),
  )->ID();

  return $self;
}

# POE related object methods

sub _start {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $self->{session_id} = $_[SESSION]->ID();

  if ( $self->{alias} ) {
	$kernel->alias_set( $self->{alias} );
  } else {
	$kernel->refcount_increment( $self->{session_id} => __PACKAGE__ );
  }

  $self->{wheel} = POE::Wheel::Run->new(
	  Program     => \&process_requests,
	  CloseOnCall => 0,
	  StdinFilter  => POE::Filter::Reference->new(),   # Child accepts input as lines.
	  StdoutFilter => POE::Filter::Reference->new(), # Child output is a stream.
	  StderrFilter => POE::Filter::Line->new(),   # Child errors are lines.
	  StdoutEvent => 'wheel_out',
	  StderrEvent => 'wheel_stderr',
	  ErrorEvent  => 'wheel_err',             # Event to emit on errors.
          CloseEvent  => 'wheel_close',     # Child closed all output.
  );

  undef;
}

sub shutdown {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  if ( $self->{alias} ) {
	$kernel->alias_remove( $_ ) for $kernel->alias_list();
  } else {
	$kernel->refcount_decrement( $self->{session_id} => __PACKAGE__ );
  }
  if ( $self->{wheel} ) {
	  $self->{wheel}->shutdown_stdin;
  }
  undef;
}

sub request {
  my ($kernel,$self,$state,$sender) = @_[KERNEL,OBJECT,STATE,SENDER];
  $sender = $sender->ID();
  
  # Get the arguments
  my $args;
  if (ref($_[ARG0]) eq 'HASH') {
	$args = { %{ $_[ARG0] } };
  } else {
	warn "first parameter must be a ref hash, trying to adjust. "
		."(fix this to get rid of this message)";
	$args = { @_[ARG0 .. $#_ ] };
  }
  
  unless ( $args->{service} or $state eq 'services' ) {
	warn "you must supply a service argument, otherwise what's the point";
	return;
  }

  unless ( $args->{event} ) {
	warn "you must supply an event argument, otherwise where do I send the replies to";
	return;
  }

  if ( $self->{wheel} ) {
	$args->{session} = $sender;
	$args->{func} = $cmd_map{ $state };
	$args->{state} = $state;
	$kernel->refcount_increment( $sender => __PACKAGE__ );
	$self->{wheel}->put( $args );
  }
  undef;
}

sub wheel_out {
  my ($kernel,$self,$input) = @_[KERNEL,OBJECT,ARG0];

  delete ( $input->{func} );
  my ($session) = delete ( $input->{session} );
  my ($event) = delete ( $input->{event} );

  $kernel->post( $session, $event, $input );
  
  $kernel->refcount_decrement( $session => __PACKAGE__ );
  undef;
}

sub wheel_stderr {
  my ($kernel,$self,$input) = @_[KERNEL,OBJECT,ARG0];

  warn "$input\n" if ( $self->{debug} );
}

sub wheel_err {
    my ($operation, $errnum, $errstr, $wheel_id) = @_[ARG0..ARG3];
    warn "Wheel $wheel_id generated $operation error $errnum: $errstr\n" if ( $self->{debug} );
}

sub wheel_close {
	warn "Wheel closed\n" if ( $self->{debug} );
}

# Object methods

sub session_id {
  return $_[0]->{session_id};
}

sub yield {
   my ($self) = shift;
   $poe_kernel->post( $self->session_id() => @_ );
}

sub call {
   my ($self) = shift;
   $poe_kernel->call( $self->session_id() => @_ );
}

# Main Wheel::Run process sub

sub process_requests {
  binmode(STDIN); binmode(STDOUT);
  my $raw;
  my $size = 4096;
  my $filter = POE::Filter::Reference->new();

  READ:
  while ( sysread ( STDIN, $raw, $size ) ) {
    my $requests = $filter->get( [ $raw ] );
    foreach my $req ( @{ $requests } ) {
	my $host = $req->{host} || "";
	my $service = $req->{service};

	SWITCH: {
	  if ( $req->{func} eq 'GetServices' ) {
	     my ($hashref) = { };
	     if ( GetServices( $host, $hashref ) ) {
		$req->{result} = $hashref;
	     } else {
		$req->{error} = &error_codes();
	     }
	     last SWITCH;
	  }
	  if ( $req->{func} eq 'GetStatus' ) {
	     my ($hashref) = { };
	     if ( GetStatus( $host, $service, $hashref ) ) {
		$req->{result} = $hashref;
	     } else {
		$req->{error} = &error_codes();
	     }
	     last SWITCH;
	  }
	  if ( $req->{func} eq 'RestartService' ) {
	     if ( StopService( $host, $service ) ) {
		$req->{result}++;
	     } else {
		$req->{error} = &error_codes();
	     }
	     sleep 2;
	     if ( StartService( $host, $service ) ) {
		$req->{result}++;
	     } else {
		$req->{error} = &error_codes();
	     }
	     last SWITCH;
	  }
	  if ( &{ $req->{func} }( $host, $service ) ) {
	  	$req->{result} = 1;
	  } else {
		$req->{error} = &error_codes();
	  }
	}
	my $replies = $filter->put( [ $req ] );
	print STDOUT @$replies;
    }
  }
}

sub error_codes {
  my $error = Win32::GetLastError();
  return [ $error, Win32::FormatMessage($error) ];
}

1;

__END__

=head1 NAME

POE::Component::Win32::Service - A POE component that provides non-blocking access to Win32::Service.

=head1 SYNOPSIS

  use POE::Component::Win32::Service;

  my ($poco) = POE::Component::Win32::Service->spawn( alias => 'win32-service', debug => 1, options => { trace => 1 } );

  # Start your POE sessions

  $kernel->post( 'win32-service' => restart => { host => 'win32server', 
					       service => 'someservice',
					       event => 'result' } );

  sub result {
    my ($kernel,$ref) = @_[KERNEL,ARG0];

    if ( $ref->{result} ) {
  	print STDOUT "Service " . $ref->{service} . " was restarted\n";
    } else {
  	print STDERR join(' ', @{ $ref->{error} ) . "\n";
    }
  }

=head1 DESCRIPTION

POE::Component::Win32::Service is a L<POE|POE> component that provides a non-blocking wrapper around
L<Win32::Service|Win32::Service>, so one can start, stop, restart, pause and resume services, query the 
status of services or just get a list of services, from the comfort of your POE sessions and applications.

Consult the L<Win32::Service|Win32::Service> documentation for more details.

=head1 METHODS

=over

=item spawn

Takes a number of arguments, all of which are optional. 'alias', the kernel alias to bless the component with;
'debug', set this to 1 to see component debug information; 'options', a hashref of L<POE::Session|POE::Session> 
options that are passed to the component's session creator.

=item session_id

Takes no arguments, returns the L<POE::Session|POE::Session> ID of the component. Useful if you don't want to use
aliases.

=item yield

This method provides an alternative object based means of posting events to the component. First argument is the event to post, following arguments are sent as arguments to the resultant post.

  $poco->yield( 'restart' => { host => 'win32server', service => 'someservice', event => 'result' } );

=item call

This method provides an alternative object based means of calling events to the component. First argument is the event to call, following arguments are sent as arguments to the resultant call.

  $poco->call( 'restart' => { host => 'win32server', service => 'someservice', event => 'result' } );

=back

=head1 INPUT

These are the events that the component will accept. Each event requires a hashref as an argument with the following keys:
'service', the short form of the service to manipulate; 'host', which host to query ( default is localhost ); 'event', the
name of the event handler in *your* session that you want the result of the requested operation to go to. 'event' is mandatory for all requests. 'service' is mandatory for all requests, except for 'services'.

It is possible to pass arbitary data in the request hashref that could be used in the resultant event handler. Simply define additional key/value pairs of your own. It is recommended that one prefixes keys with '_' to avoid future clashes.

=over

=item start

Starts the requested service on the requested host.

=item stop

Stops the requested service on the requested host.

=item restart

Stops and starts the requested service on the requested host.

=item pause

Pauses the requested service on the requested host.

=item resume

Resumes the requested service on the requested host.

=item status

Retrieves the status of the requested service on the requested host.

=item services

Retrieves a list of services on the requested host.

=back

=head1 OUTPUT

For each requested operation an event handler is required. ARG0 of this event handler contains a hashref.

The hashref will contain keys for 'service', 'host' and 'state'. The first two are those passed in the original query. 'state' is the operation that was requested.

=over

=item result

For most cases this will be just a true value. For 'status', it will be a hashref that will be populated with entries corresponding to the SERVICE_STATUS structure of the Win32 API. See the Win32 Platform SDK documentation for details of this structure. For 'services' it will be a hashref populated with the descriptive service names as keys and the short names as the values.

=item error

In the event of an error occurring this will be defined. It is an arrayref which contains the error code and the formatted error relating to that code.

=back

=head1 CAVEATS

This module will only work on Win32. But you guessed that already :)

=head1 AUTHOR

Chris Williams <chris@bingosnet.co.uk>

=head1 SEE ALSO

L<Win32::Service|Win32::Service>
