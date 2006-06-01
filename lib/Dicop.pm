#############################################################################
# Dicop -- routines shared between the server and/or client part
#
# (c) Bundesamt fuer Sicherheit in der Informationstechnik 1998-2006
#
# DiCoP is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License version 2 as published by the Free
# Software Foundation.
#
# See the file LICENSE or L<http://www.bsi.de/> for more information.
#############################################################################

package Dicop;
use vars qw($VERSION $BUILD $BASE_MIN_VER @ISA @EXPORT_OK);
use strict;

$VERSION = '3.03';		# Current version of this package
$BUILD = 0;			# Current build of this package
$BASE_MIN_VER = '3.003000';	# We need at least this build of Dicop::Base
require 5.008001;		# requires this Perl version or later

require Exporter;
@ISA = qw(Exporter);
@EXPORT_OK	= qw( UNKNOWN DONE ISSUED SOLVED TOBEDONE FAILED SUSPENDED
		      TIMEOUT VERIFY BAD WAITING
                      MAX_ISSUED_AGE MAX_FAILED_AGE
		      status status_code
                    );

# constants for chunk and job status
# (job can be TOBEDONE (still running), FAILED (no result), SOLVED (found one)
sub UNKNOWN	() { 0; }
sub ISSUED	() { 1; }	# chunk was issued to client
sub DONE	() { 2; }	# chunk contains no result
sub TOBEDONE	() { 3; }	# chunk/job/task still to be checked/done
sub SOLVED	() { 4; }	# chunk/job contains result
sub FAILED	() { 5; }	# task/job failed (no result at all in keyspace)
sub SUSPENDED	() { 6; }	# task/job halted temp.
sub TIMEOUT	() { 7; }	# chunk not completed in time
sub VERIFY	() { 8; }	# chunk done/solved by one client, but needs
				# further verification checks
sub BAD		() { 9; }	# chunk verify failed
sub WAITING	() { 10; }	# task waits to be TOBEDONE

my @status = qw/
	unknown issued done tobedone solved failed suspended
	timeout verify bad waiting
  /;

my $statush = { unknown => 0, issued => 1, done => 2, tobedone => 3, 
                solved => 4, failed => 5, suspended => 6, timeout => 7,
		verify => 8, bad => 9, waiting => 10, };

# number of hours until ISSUED chunk is reissued
sub MAX_ISSUED_AGE () { 6; }
# number of hours until FAILED chunk is reissued
sub MAX_FAILED_AGE () { 1; }

sub status
  {
  my $s = shift || 0;
  $status[$s] || 'UNKNOWN';
  }

sub status_code
  {
  my $txt = lc(shift);

  return -1 if !exists ($statush->{$txt});
  $statush->{$txt};
  }

sub base_version
  {
  eval { require Dicop::Base; };

  sprintf("%.3f%03i", $Dicop::Base::VERSION || '0', $Dicop::Base::BUILD || '0');
  }

1;

__END__

#############################################################################

=pod

=head1 NAME

Dicop - routines shared between the server and/or client part

=head1 SYNOPSIS

	use Dicop;

=head1 REQUIRES

perl5.008003, Exporter

=head1 EXPORTS

Exports nothing on default.

=head1 DESCRIPTION

Contains an assortment of often used or handy support routines used by the
server/proxy and the client.

=head1 METHODS

=head2 status

Map a given status code to the status code name, e.g.:

	Dicop::status(1);	# return 'issued'

  {
  my $s = shift || 0;
  return $status[$s] || 'UNKNOWN';
  }

=head2 status_code

Given a status code name, returns the status code:

	$done = dicop::Status_code('DONE');

=head2 base_version

Returns version and build number of Dicop::Base as a string that can be
used as a float for comparing.

=head1 BUGS

None known yet.

=head1 AUTHOR

(c) Bundesamt fuer Sicherheit in der Informationstechnik 1998-2006

DiCoP is free software; you can redistribute it and/or modify it under the
terms of the GNU General Public License version 2 as published by the Free
Software Foundation.

See the file LICENSE or L<http://www.bsi.de/> for more information.

=cut
