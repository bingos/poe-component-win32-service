# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl 1.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use Test::More tests => 3;
BEGIN { use_ok('POE::Component::Win32::Service') };

#########################

use POE;

my ($self) = POE::Component::Win32::Service->spawn();

isa_ok ( $self, 'POE::Component::Win32::Service' );

POE::Session->create(
	inline_states => { _start => \&test_start, },
);

$poe_kernel->run();
exit 0;

sub test_start {
  my ($kernel,$heap) = @_[KERNEL,HEAP];

  pass('blah');
  $kernel->post( $self->session_id() => 'shutdown' );
}

