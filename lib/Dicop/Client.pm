#############################################################################
# Dicop::Client -- usefull methods for a client
#
# (c) Bundesamt fuer Sicherheit in der Informationstechnik 1998-2006
#
# DiCoP is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License version 2 as published by the Free
# Software Foundation.
#
# See the file LICENSE or L<http://www.bsi.de/> for more information.
#############################################################################

package Dicop::Client;
use vars qw/@ISA $VERSION $BUILD $NO_STDERR/;
$VERSION = '3.01';	# Current version of this package
$BUILD = $Dicop::BUILD;	# Current build of this package
require  5.006;		# requires this Perl version or later

$NO_STDERR = 0;
@ISA = qw/Dicop::Item/;

use strict;

use Dicop::Event qw/crumble msg logger load_messages/;
use Dicop::Config;
use Dicop::Item;
use Dicop::Request;
use Dicop::Request::Pattern;
use Dicop::Base qw/decode encode write_file/;
use Dicop::Hash;
use File::Spec;
use Dicop;
use POSIX;

use Dicop::Connect qw/_connect_server _load_connector/;

sub new
  {
  # create a new client object
  my $class = shift;
  $class = ref($class) || $class || 'Dicop::Client';
  my $self = {};
  bless $self, $class;
  $self->_init(@_);
  $self;
  }

sub _load_messages
  {
  my $self = shift;
  my $cfg = $self->{cfg};

  my $msg_file = File::Spec->catfile($cfg->{msg_dir},$cfg->{language} || 'en', $cfg->{msg_file} || 'messages.txt');
  if (!-e $msg_file || !-f $msg_file)
    {
    $msg_file = File::Spec->catfile($cfg->{msg_dir},$cfg->{msg_file});
    }
  Dicop::Event::load_messages( $msg_file) or die();
  }

sub _load_request_patterns
  {
  my $self = shift;

  # load request.def file

  my $cfg = $self->{cfg};

  my $pattern_file = File::Spec->catfile($cfg->{def_dir}, $cfg->{patterns_file} || 'request.def');

  $self->{request_patterns} = [ Dicop::Item::from_file ( $pattern_file,
        'Dicop::Request::Pattern', ) ];

  foreach my $p (@{$self->{request_patterns}})
    {
    if (ref($p) ne 'Dicop::Request::Pattern')
      {
      require Carp; Carp::croak($p);
      }
    $p->_construct();
    # check for errors
    if ($p->error() ne '')
      {
      require Carp; Carp::croak($p->error());
      }
    }

  $self;
  }

sub _init
  {
  # read in config, set up data
  my $self = shift;
  my $args = $_[0] || {};
  ref $args ? $args = shift : $args = { @_ };

  my $cfg = $args->{config} || 'config/client.cfg'; 
  $self->{debug} = abs($args->{debug} || 0);		# 0...
  $self->{chunks} = abs($args->{chunks} || 0);		# 0...
  $self->{test} = abs($args->{test} || 0);		# == 0 or != 0
  $self->{type} = abs($args->{type} || 0);		# == 0 or != 0
  
  $self->{done_chunks} = 0;

  $self->{sleeped} = 0;					# did not sleep yet
  $self->{sleep_factor} = 1;
  
  # what we still need to do
  $self->{todo} = [];
  # what we have to send to the server
  $self->{tobesent} = {};

  # read in configuration file
  $cfg = Dicop::Config->new($cfg);
 
  $cfg->{server} = $args->{server} if $args->{server};
  # provide some sensible defaults
  my %defaults = ( 
    wait_on_error => 240,
    wait_on_idle => 600,
    chunk_size => 20,
    cant_work_on => '',
    chunk_count => 1,
    retries => 16,
    error_log => "client_##id##.log",
    log_dir => 'logs',
    msg_dir => 'msg',
    def_dir => 'def',
    msg_file => 'messages.txt',
    patterns_file => 'client_request.def',
    update_files => '0',
    language => 'en',
    server => 'dicop-server',
    sub_arch => '',
  );
  foreach (keys %defaults)
    {
    $cfg->{$_} = $defaults{$_} if !defined $cfg->{$_};
    }

  if ($cfg->{server} ne '')
    {
    $cfg->{server} = 'http://' . $cfg->{server}
      if $cfg->{server} !~ /^[a-z]+:\/\//;
  
    if ($cfg->{server} !~ /:[\d]+/)
      {
      # default port is 8888
      $cfg->{server} .= ':8888';
      }
    # add trailing slash
    $cfg->{server} = $cfg->{server} .= '/' 
      if $cfg->{server} !~ /\/$/;			
    }
  
  # override cfg settings with command line arguments
  $cfg->{language} = $args->{language} || $cfg->{language};
  $cfg->{chunk_count} = abs($args->{chunk_count} || $cfg->{chunk_count} || 1);
  $cfg->{retries} = abs($args->{retries} || $cfg->{retries} || 16);
  $self->{id} = $args->{id} || $cfg->{id} || 0;
  
  $self->{user} = $args->{user} || $cfg->{user} || '';
  $self->{group} = $args->{group} || $cfg->{group} || '';
  $self->{chroot} = $args->{chroot} || $cfg->{chroot} || '';
  
  $cfg->{error_log} =~ s/##(.*?)##/$self->{$1}||'0'/eg;
 
  $self->{logfile} = "$cfg->{log_dir}/$cfg->{error_log}";
  $cfg->{sub_arch} = $args->{sub_arch} if $args->{sub_arch}; # overwrite from cmd line
  $cfg->{sub_arch} = lc($cfg->{sub_arch});
  $cfg->{sub_arch} =~ s/[^a-z0-9\-_]+//g;			# only a-z0-9_ and -
  $cfg->{sub_arch} =~ s/-+//;					# -- => -
  $cfg->{sub_arch} =~ s/^-//;					# remove leading '-'
  $self->{arch} = lc($args->{arch} || $^O);
  $self->{arch} =~ s/[^a-z0-9\-_]+//g;

  $self->{cfg} = $cfg;

  $self->_load_messages();
 
  $cfg->{id} = $self->{id} || $self->_die_hard ( msg (601), 
    "$cfg->{log_dir}/$cfg->{error_log}" );

  # load module helping us to connect servers/proxies and construct UserAgent
  $self->_load_connector($cfg,$args);  

  ###########################################################################
  # try to get info on cpu
  my $cpuinfo = Dicop::Base::cpuinfo($self,$args->{_no_warn});

  ###########################################################################
  # load request.def file
  $self->_load_request_patterns();
 
  # the request IDs below will be changed everytime before we send the
  # request identifying us

  my $pid = $$ || 0;
  my $arch = $self->{arch}; $arch .= '-' . $cfg->{sub_arch} if $cfg->{sub_arch};

  $self->{ident} = Dicop::Request->new( id => 'req0001', 
   data => "cmd_auth;id_$self->{id};version_$VERSION-$BUILD;pid_$pid;arch_$arch$cpuinfo",
   patterns => $self->{request_patterns},
   );
  # request for test cases
  $self->{test_cases} = Dicop::Request->new( id => 'req0002', 
   data => "cmd_request;type_test", 
   patterns => $self->{request_patterns},
   );
  # request for more work
  $self->{more_work} = Dicop::Request->new( id => 'req0002', 
   data => "cmd_request;type_work;" 
         . "size_$cfg->{chunk_size};count_$cfg->{chunk_count};", 
   patterns => $self->{request_patterns} );
 
  $self->_store ($self->{ident});

  # will contain hashes for workers and target files keyed on name
  $self->{file_hash} = {};

  # contains later path/filename of temporary files that should be
  # deleted after the chunk has been finished
  $self->{temp_files} = {};

  $self->{updir} = File::Spec->updir();
  $self->{double_updir} = File::Spec->catdir($self->{updir}, $self->{updir});

  $self;
  }

sub change_root
  {
  my $self = shift;

  output ("Changing root to '",$self->{chroot},"'\n");

  if ($^O =~ /win32/i)
    {
    warn ("Warning: Cannot chroot under '$^O'\n\n");
    return;
    }

  chroot($self->{chroot}) if $self->{chroot} ne '';
  }

sub change_user_and_group
  {
  my $self = shift;

  my $cfg = $self->{cfg};
  $cfg->{user} ||= '';
  $cfg->{group} ||= '';

  if ($^O =~ /win32/i)
    {
    warn ("Warning: Cannot set user and group under '$^O'\n\n");
    return;
    }

  my $uid = 0; my $gid = 0;
  $uid = main::get_uid($cfg->{user}) || 0 if $cfg->{user} ne '';
  $gid = main::get_gid($cfg->{group}) || 0 if $cfg->{group} ne '';

  output ("Changing user and group to '",
	$self->{user},"' ($uid) and '", $self->{group},"' ($gid)\n\n");

  main::set_gid($gid) if $gid;
  main::set_uid($uid) if $uid;

  }

##############################################################################

sub _talk_to_server
  {
  # send our requests to the server, then handle his responses
  my $self = shift;

  # add as params the requests we are going to send, starting with our
  # authentication request
  my $params = "";
  foreach (sort keys %{$self->{tobesent}})
    {
    $params .= $self->{tobesent}->{$_}->as_request_string().'&';
    } 
  chop $params;	# remove trailing '&'

  my $res = $self->_connect_server(undef,$params,$self->{cfg}->{retries});
  my $rc = $self->_handle_responses( $self->_parse_responses($res) );
  $self->_clear_send_queue() if $rc != 0;	# hard error?
  $rc;
  }
  
sub _clear_send_queue
  {
  # hard error, need to clear send stuff as to not retry it
  # clear anything except our ident, then add a work request back
  my ($self) = @_;

  $self->{tobesent} = {};
  $self->_store ($self->{ident});
  $self->_get_more_work();
  $self;
  }

sub _delete_temp_files
  {
  # Delete/unlink all temporary files sent by the server for this chunk
  # File that couldn't be unlinked will remain and be tried later on again
  my ($self) = @_;

  foreach my $file (keys %{$self->{temp_files}})
    {
    unlink $file;
    if (-f $file)
      {
      output ("Warning: Could not unlink temp. file '$file'.\n");
      }
    else { delete $self->{temp_files}->{$file}; }
    }
  }  

sub _parse_responses
  {
  # parse the servers response into requests, and throw away any garbage/junk
  # input: response object from server, or scalar (for tests)
  # return: ref to array with [ response_id, response_code, response_text]
  # responses: list of valids responses
  # error:     global error code
  # error_msg: error message if error code != 0

  my ($self,$res) = @_;
  my @lines;
  
  if (ref $res)
    {
    @lines = split /\n/,$res->content;
    }
  else
    {
    @lines = split /\n/,$res;
    }
  my @r;
  foreach (@lines)
    { 
    output ("line $_\n") if $self->{debug} > 2;
    $_ =~ 
     s/^(req[0-9]{4})\s+([0-9]+)\s+(.*)/push @r,[$1,$2,$3] if $2 > 100;/e;
    }
  \@r;
  }
          
sub _parse_responses_for_files
  {
  my ($self,$r) = @_;

  my $unique = {};			# store all file names we need
  foreach my $id (@$r)
    {
    my $code = $id->[1];

    if ($code == 101 || $code == 102)
      {
      # server requested us to check/update a certain file
      $id->[2] =~ /^([a-fA-F0-9]+)\s"(.*)"/;
      my $hash = $1 || '';
      my $file = $2 || '';
      output ("Got message #$code: $id->[2]\n") if $self->{debug} > 0;
      if (($hash ne '') && ($file ne ''))
        {
        if ((!exists $unique->{$file}) && (!$self->_check_file($file,$hash)))
	  {
	  # we don't have yet the right version, so mark it to be downloaded
          $unique->{$file} = $hash;
	  }
        }
      else
        {
        my $m = "Ignoring malformed msg $code: $id->[2]";
        logger($self->{logfile},$m);
        output ("$m\n");
        }
      }
    elsif ($code == 111 || $code == 112)
      {
      # server inlined a file for use
      $id->[2] =~ /^([a-fA-F0-9]+)\s"(.*?)" "(.*)"/;
      my $hash = $1 || '';
      my $file = $2 || '';
      my $data = decode($3 || '');
      output ("Got message #$code: $id->[2]\n") if $self->{debug} > 0;
      if (($hash ne '') && ($file ne '') && ($data ne ''))
        {
        # write the data to the disk
        if (!exists $unique->{$file})
          {
	  write_file($file,\$data);
	  if (!$self->_check_file($file,$hash))
	    {
	    # We still don't have the right version, so the data from the
	    # server was faulty. Mark for downloaded (but this won't work)
	    $unique->{$file} = $hash;
	    }
	  }
        }
      else
        {
        my $m = "Ignoring malformed msg $code: $id->[2]";
        logger($self->{logfile},$m);
        output ("$m\n");
        }
      }
    elsif ($code == 200)
      {
      # the chunk contains the worker name and hash and we need to make sure we got
      # the right worker:

      my $c = $self->_break_chunk($id->[2]);
      my ($path,$wname) = $self->_worker_name($c);
      my $file = "$path/$wname"; my $hash = $c->{hash};
      if ((!exists $unique->{$file}) && (!$self->_check_file($file,$hash)))
        {
	# we don't have yet the right version, so mark it to be downloaded
        $unique->{$file} = $hash;
        }
      }
    } # end for all responses
 
  $unique;
  }

sub _handle_responses
  {
  # From the servers response, clear any 'handled' request from our send
  # list. After doing this, anything that needs to be send again will be in the
  # send stack, including our authentication, anything other was nuked
  # chunks of work/test will be added to our todo list
  # format of response list: [ request_id, code, message ]
  my $self = shift;
  my $r = shift;
  my $t = shift;	# for tests, be silent

  output ("Client $self->{id} got " . scalar @$r . " messages from server.\n") if !$t;
  
  my $error = [ 0, 0 ]; 
  foreach (@$r) 
    {
    if ($_->[1] >= 300)
      {
      $error = $_;
      }
    last if $_->[1] >= 450;			# hard errors take precedence
    }
  
  my $code = $error->[1];
  if ($code >= 300)				# hard or soft error?
    {
    $self->_sleeping($error->[1],"$error->[2]\n ") if !$t;
    # some hard error, so stop working immidiately (outer hull can restart us)
    # error code 463 will also fall into this range (meaning server asks us
    # to terminate)
    return 1 if $code >= 450 && $code < 500;
    # other errors
    return 0 if $code >= 500;			# server hickup, retry all
    # < 450 are "soft" errors and will be retried on a per-request basis
    }

  # parse the response, and not all the file we need to download first
  my $files = $self->_parse_responses_for_files($r);

  # now try to download the missing files
  my $answers = $self->_retrieve_files($files);
  
  my $bad_answers = {};	# when some files for the specific request are missing,
			# simple ignore it
  my $delete = {};				# id's of requests to delete
  foreach my $id (@$r)
    {
    my $req = $self->{tobesent}->{$id->[0]};
    $code = $id->[1];
    if ($code == 101 || $code == 102 || $code == 111 || $code == 112)
      {
      # server requested us to check/update a certain file
      $id->[2] =~ /^([a-fA-F0-9]+)\s"(.*?)"/;
      my $hash = $1 || '';
      my $file = $2 || '';
      if (($hash ne '') && ($file ne ''))
	{
        # we already downloaded the files above, so it should now exist
        if ($self->_file_ok($file,$hash) != 0)
	  {
          $self->_sleeping(605,msg(605,$file)) if !$t;

	  # If the req ID is req0000, the file to be checked is absolutely
	  # required for all requests. If we can't get it, refuse to work
	  # anymore, so bail out early and hard:
	  return 1 if $id->[0] eq 'req0000';

	  # If we couldn't get a file tied to a specific request, remember this
          # so that we can refuse only this single request
          $bad_answers->{$id->[0]}++;
	  # and send back FAILED to server to notify it
          my $data = 'cmd_report;status_FAILED;took_0;crc_0;reason_' .
                     encode(scalar localtime() . " Couldn't+download+file+'$file'+for+request+$id->[0]");
	  $self->_store( $data );
          }
	# could download temporary file, so remember to delete it afterwards
        elsif ($code == 102 || $code == 112)
	  {
	  $self->{temp_files}->{$file} = undef;
	  }
	}
      # if the message 101/102/111/112 was malformed, silently ignore (already
      # logged it in _parse_responses_for_files()
      next;
      }
    elsif ($code <= 199)
      {
      # system/status messages
      output ("System message: $id->[2]\n") if !$t;
      }
    next unless defined $req;			# answer does not match??

    next if $req->{cmd} eq 'auth';		# skip authentication
   
    # code <= 199 already done first 
    if ($code == 200)
      {
      # remember work requests, but only when they are not in bad_answers
      # (which means we haven't got all nesseccery files properly)
      if (exists $bad_answers->{$id->[0]})
        {
        output ("Cannot work on req $id->[0] since some files are missing.\n")
         if $self->{debug} > 1;
        }
      else
        {
        push @{$self->{todo}}, $id->[2];
        output ("Work for me on req $id->[0]: $id->[2]\n")
         if $self->{debug} > 1;
        }
      }
    elsif ($code <= 299)
      {
      # report accepted
      output ("Server accepted $id->[0] $code: $id->[2]\n") if $self->{debug} > 1;
      }
    elsif ($code <= 399)
      {
      output ("NOK retry $code on $id->[0]: $id->[2]\n") if $self->{debug} > 1;
      next; 					# nok, retry it
      }
    # anything left over is (>= 400 && < 450)
    # (450+ was ignored/handled at top)
    # delete only after reqs are handled in case more than one answer comes	
    $delete->{$id->[0]} = 1;
    }
  # now we can safely delete 'em
  foreach (keys %$delete)
    {
    delete $self->{tobesent}->{$_};
    }
  output ("Chunks to work on: ",scalar @{$self->{todo}},"\n") if !$t;
  0;						# no error, maybe got some work
  }

sub _store
  {
  # one (ore more) request(s) is (are) added to the list of to-be-sent items
  # input:  list of Dicop::Request, or scalars holding strings
  # output: count of requests in send-list
  my $self = shift;

  return '' if @_ == 0;					# no results 
  # the IDs are counting from '0001' upwards
  my $id = 'req0001';
  foreach my $r (@_)
    {
    # skip over already existing IDs
    $id++ while exists $self->{tobesent}->{$id};
    if (ref ($r) eq 'Dicop::Request')
      {
      $self->{tobesent}->{$id} = $r;
      # change the request's id to match
      $self->{tobesent}->{$id}->request_id($id);
      }
    else
      {
      $self->{tobesent}->{$id} = Dicop::Request->new( 
	id => $id, data => $r, patterns => $self->{request_patterns} );
      }
    }
#  print "in store:\n";
#  for (sort keys %{$self->{tobesent}})
#    {
#    print $self->{tobesent}->{$_}->request_id()," ";
#    print $self->{tobesent}->{$_}->as_request_string(),"\n";
#   }
  }

sub _work_on_chunks
  {
  # parse the list of chunks the server sent us and work on them
  my $self = shift;

  return $self->_sleeping(0) if (@{$self->{todo}} == 0);
  
  my ($result,$data);
  foreach my $chunk (@{$self->{todo}})
    {
    output ("Working on $chunk ($self->{done_chunks} of $self->{chunks})\n")
     if $self->{debug} > 1;
    output (scalar localtime()," ");

    # break down message (chunk) from server into parts
    my $c = $self->_break_chunk($chunk);

    my $wn = $c->{worker};
    $wn =~ s/\-.*$//;			# remove possible version

    # if we got a CDF (chunkfile not set, but set is a file)
    $c->{chunkfile} = "../../$c->{set}" if !$c->{chunkfile} && -f $c->{set};

    if (exists $c->{chunkfile})
      {
      # call like ./worker target/data/JOBID/JOBID_CHUNKID.txt
      # or   like ./worker target/data/JOBID/JOBID.set
      output ("$wn \"$c->{chunkfile}\"\n");
      }
    else
      {
      # call like ./worker start end target charset timeout
      output ("$wn $c->{start} $c->{end}\n");
      }

    my $took = 0;
    ($data,$result,$took) = $self->_start_worker($c); $self->_store( $data );
    output (scalar localtime()," took $took"." seconds, result: $result\n");
    $self->{done_chunks}++;
    return 1		# stop working
      if ($self->{chunks} > 0 && $self->{done_chunks} >= $self->{chunks});
    }
  $self->{todo} = [];			# remove all chunks from todo queue
  $self->_delete_temp_files();		# remove temp. files
  0;					# tell caller we want to work again
  }

sub _break_chunk
  {
  # break down a chunk-string from server into parts and return hash
  my ($self,$chunk) = @_;
  my $hash = {};

  my @parts = split /;/,$chunk;
  my ($name,$val);
  foreach my $p (@parts)
    {
    ($name,$val) = split /_/,$p;
    $val = decode($val || '');
    if ($val =~ /,/)
      {
      $val = [ split /,/,$val ];
      }
    $hash->{$name} = $val; 
    }
  $hash;
  }

sub _extract_result
  {
  # from the output of the worker, extract the result, stopcode and crc
  my ($self,$rc) = @_;
  my $code = -1; my $res = ''; my $crc = '0xcafebabe';

  $code = $1 if $rc =~ /\bStopcode is '([0-9]+)'/i;
  # extract crc
  $crc = $1 if $rc =~ /\bCRC is '([0-9a-fA-F]+)'/i;
  $res = $1 if $rc =~ /\bLast tested password in hex was '([A-Fa-f0-9]+)'/i;
  ($code,$res,$crc);
  }

sub _worker_name
  {
  # construct worker name from parts of the chunk and our base architecture
  my ($self,$chunk) = @_;
  
  # Don't use File::Spec, because this produces "worker\win32/foo" under win32
  # which will then be rejected by the server as an invalid file name
  my $path = "$self->{cfg}->{worker_dir}/$self->{arch}";
  my $wname = $chunk->{worker};
  $wname =~ s/\-[0-9\.]+$//;			# remove version number

  # if no extension, and we are under win32, add .exe
  $wname .= '.exe' if $self->{arch} =~ /win32/i && $wname !~ /\.(\w+)$/;

  ($path,$wname);
  }

sub _start_worker
  {
  my $self = shift;
  my $chunk = shift;

  my $data = "cmd_report;status_";

  my ($path,$wname) = $self->_worker_name($chunk);

  output ("Running " . File::Spec->catfile($path,$wname) . "...\n") if $self->{debug} > 2;
  my $to = $self->{cfg}->{chunk_maxsize} || 300; $to *= 60;	# in seconds

  my $status = 'FAILED'; my $crc = ''; my $code = -1; my $took = 0;
  my $res = ''; my $reason = '';

  if ($wname =~ /\.pl$/)
    {
    $wname = "perl $wname";
    }
  else
    {
    $wname = File::Spec->catfile(File::Spec->curdir(),$wname)
      unless $self->{arch} =~ /win32/i;
    }
  my $tg = $chunk->{target} || '';
  my $new_target = File::Spec->catdir($self->{double_updir},'target');
  $tg =~ s/^target/$new_target/;	# target/file => ../../target/file
    
  # limit length of data given to worker to prevent buffer overflows
  if (exists $chunk->{chunkfile})
    {
    my $chunk_file = $chunk->{chunkfile};
    $chunk_file = substr($chunk_file,0,250) if length($chunk_file) > 250;
    $wname .= " \"$chunk_file\" $to";
    }
  else
    {
    my $start = $chunk->{start};
    my $end = $chunk->{end};
    my $set = $chunk->{set};
    $start = substr($start,0,250) if length($start) > 250;
    $end = substr($end,0,250) if length($end) > 250;
    $set = substr($set,0,128) if length($set) > 128;
    $set =~ s/^target/$new_target/;	# target/file => ../../target/file
    $wname .= " $start $end $tg $set $to";
    }

  output ("Chdir to '$path'...\n") if $self->{debug};
  chdir ($path);						# chdir down
  output ("Starting '$wname'...\n") if $self->{debug};

  # win32 loads DLLs from the current directory by default, linux & solaris
  # should do this, too, so enable it:
  if ($self->{arch} =~ /(linux|solaris)/)
    {
    # XXX TODO: does this assume BASH?
    $wname = 'export LD_LIBRARY_PATH=.; ' . $wname;
    }

  my $starttime = time;
  my $rc = `$wname`; $rc = $! unless defined $rc;

  output ("Chdir to '$self->{double_updir}'...\n") if $self->{debug};
  chdir ($self->{double_updir});				# chdir back
  output ("Got '$rc'\n") if $self->{debug} > 1;
  $took = time - $starttime;
  ($code,$res,$crc) = $self->_extract_result($rc);
  if ($code >= 0)
    {
    $status = 'DONE' if $code == 0; 			# nocheck for min time (took<2)
    $status = 'SOLVED' if $code == 1 && $res ne '';
    $status = 'TIMEOUT' if $code == 2;			# took too long?
    } 
  $reason = "On " . scalar localtime() 
    . " Tried:\n '$wname'\nFailed with:\n" 
    . substr($rc,0,4096)
   if $code > 2 || $code < 0;				# error msg  

  output ("Got $code => $res\n") if $self->{debug};
  $data .= "$status;took_$took;";			# append status
  $data .= "result_$res;" if $status ne 'DONE';		# append result only if necc.
  foreach my $p (qw/token job chunk/)			# and other data
    {
    $data .= $p . "_$chunk->{$p};" if defined $chunk->{$p};
    }
  # append error messsage if unknown result (code = -1) or error (code > 2)
  $data .= 'reason_' . substr(encode($reason),0,4096) . ';'
    if ($code < 0 || $code > 2);

  # append also CRC from worker
  $data .= "crc_$crc";
  output ("Will return to server:\n  $data\n") if $self->{debug};
  $self->_sleeping(604,msg(604,$wname)) if $code < 0;
  return ($data,$status,$took);
  }

sub _check_file
  {
  # before trying to download, this this tries to find out whether we already have
  # the right file by comparing the hash. Return true for yes.
  my ($self,$file_org,$hash) = @_;

  my $file = $self->_remove_sub_arch($file_org);
 
  $hash ||= '';
  if (-e $file)
    {
    # file exists, so check that it is a regular file
    if (!-f $file)
      {
      output ("Error: '$file' is not a regular file. Cannot overwrite it.\n");
      return 0;
      }
    # create Dicop::Hash object if we don't have already one
    if (!exists $self->{file_hash}->{$file})
      {
      $self->{file_hash}->{$file} = Dicop::Hash->new($file); 
      }
    if ($self->{file_hash}->{$file}->as_hex() ne $hash)
      {
      output ("File '$file' outdated, trying to upgrade it.\n");
      return 0;							# need to get file
      }
    return 1;							# file is ok
    }
  
  output ("File '$file' does not exist, trying to get it.\n");
  0;								# need to get file
  }

sub _file_ok
  {
  # after trial download of a file, check that it exists now with the correct hash
  my ($self,$file, $hash) = @_;

  $file = $self->_remove_sub_arch($file);
  # if something is still wrong:
  if (!-e $file)
    {
    output ("After trying to retrieve it, '$file' does still not exist.\n");
    return 1;
    }

  if ($self->{file_hash}->{$file}->as_hex() ne $hash)
    {
    output ("After trying to retrieve it, '$file' still outdated.\n");
    output ("Hash is " .
            $self->{file_hash}->{$file}->as_hex() .
            ", but should be $hash\n");
    return 1;
    }

  0;			# everything is ok
  }

sub _sleeping
  {
  # no work, so wait and retry later on 
  my $self = shift;
  my $e = shift || 0;
  my $err = shift || '';

  my $type = 'wait_on_idle'; $type = 'wait_on_error' if $e != 0;

  $err =~ s/^[0-9]+//;				# remove possible error nr
  my $sleep = abs($self->{cfg}->{$type} || 300);
  $sleep *= $self->{sleep_factor};
  $self->{sleep_factor} *= 2 if $self->{sleep_factor} < 8;	# 1,2,4,8,16
  $self->{sleeped} = 1;						# did sleep
  if ($e != 0)
    {
    output ("Error $e $err");
    output (" while talking to server") if $e < 600;
    }
  else
    {
    output ("Currently nothing to do")
    }
  output (" - sleeping for $sleep seconds...\n");
  sleep ($sleep);
  0;
  }

sub _get_more_work
  {
  # get more work, unless we already have a request for work in our queue
  my $self = shift;
 
  my $tbs = $self->{tobesent}; 
  foreach my $r (keys %$tbs)
    {
    return if $tbs->{$r}->{cmd} eq 'request' && $tbs->{$r}->{type} eq 'work';
    }
  # none yet, so get something fresh
  $self->_store($self->{more_work});	# push request for more work
  }

sub work
  {
  my $self = shift;

  output (msg (600),"\n");   		# start work

  my $done = 0;
  if ($self->{test} == 1)
    {
    $self->_store($self->{test_cases});	# push request for test cases
    $done += $self->_talk_to_server();	# get test cases
    $done += $self->_work_on_chunks();	# let worker chew test cases
    }

  while ($done == 0)
    {
    $self->{sleeped} = 0;		# reset error counter
    $self->_get_more_work;		# push request for more work
    $done += $self->_talk_to_server();	# report results and get more work
    $done += $self->_work_on_chunks();	# let worker do something (or not)
    $self->{sleep_factor} = 1
      unless $self->{sleeped};		# nothing bad happened underway?
    }
  output (msg (603),"\n\n");   		# done work
  }

sub _retrieve_files
  {
  # Given a list of no-existing or not-uptodate files, will connect DiCoP server and ask
  # it for URIs, then try to download all the files. Returns 0 for all files could be
  # downloaded, or otherwise the number of files that failed.
  my ($self,$files) = @_; 

  return if scalar keys %$files == 0;	# nothing to do?
  
  output ("Need to download " . (scalar keys %$files) . " files...\n");

  my $params = $self->{ident}->as_request_string() . '&';
  my $req_id = 'req0002';

  # for each file, we can get multiple URIs, so we record all of them here:
  my $answers = { };

  foreach my $name (sort keys %$files)
    {
    my $hash = $files->{$name};

    $params .= Dicop::Request->new( id => $req_id, 
      data => "cmd_request;type_file;name_" . encode($name), patterns => $self->{request_patterns} 
      )->as_request_string() . '&';
    # store the request ID and an empty list of download locations (to see if we really get one
    # for each file)
    $answers->{$req_id} = { name => $name, hash => $hash, URIs => [ ] };
    $req_id++;
    }

  # now connect to server and parse its response
  my $r = $self->_parse_responses ( $self->_connect_server(undef,$params) );

  # extract all URIs from responses
  my $error = [ 'req0000', '500', 'Unknown error' ];
  foreach my $req (@$r)
    {
    # find out from req ID to which of our initial requests this belongs to
    if (exists $answers->{$req->[0]})
      {
      if ($req->[1] > 400)			# some error? Store it
	{
	$answers->{$req->[0]}->{error} = $req;
	}
      else
	{
        push @{$answers->{$req->[0]}->{URIs}}, $req->[2];	# store URI
	}
      }
    # else: ignore answer from server
    }

  my $errors = 0;

  # now check that each file got at least one URI to download from
  # and if everything is ok, download it
  foreach my $rid (sort keys %$answers)
    {
    my $ans = $answers->{$rid};
    my $file = $ans->{name};
    $error = $ans->{error};
    if ($error)
      {
      output ("Server error while trying to get URI for '$file'.\n");
      output ("Error code from server: ",$error->[1], ' ', $error->[2],"\n");
      $errors++;
      next;
      }
    if (@{$ans->{URIs}} == 0)
      {
      output ("Server did not send me any URI for '$file', cannot get file.\n");
      output ("Error code from server: ",$error->[1] || 'unknown', ' ', $error->[2] || 'unknown',"\n");
      $errors++;
      next;
      }
    $errors += $self->_download_file($file, $ans->{hash}, $ans->{URIs});
    }
  $errors;
  }

sub _remove_sub_arch
  {
  my ($self,$file) = @_;
  
  if ($self->{cfg}->{sub_arch})
    {
    my $subs = $self->{cfg}->{sub_arch};
    $subs =~ s/-/\//g;			# linux-i386-amd => linux/i386/amd
         
    $file =~ s/(worker\/$self->{arch})\/$subs\//$1\//;
    }
  $file;
  }

sub _download_file
  {
  # Connect to a file server and download an file, then check it's hash
  # against the given hash. Logs error if something went wrong.
  my ($self, $name, $hash, $uris) = @_;

  # Try all URIs to find one working
  for (my $i = 0; $i < @$uris; $i++)
    {
    my $uri = $uris->[ $i ];
    # now try to download the file
    my $res = $self->_connect_server($uri,undef,undef,1);
    if ($res->is_success())
      {
      # now write retrieved data to disk and hash it

      # if the name contains worker/$architecure-$subarch/ we must
      # remove the subarch from it first
      my $filename = $self->_remove_sub_arch($name);
      output ("Storing it as '$filename'...") if $self->{debug};

      write_file($filename, \$res->content());
      output ("ok.\n") if $self->{debug};

      # if worker, make it executable
      chmod 0755, $filename if ($name =~ /^worker\//);

      # if hash doesn't exist, create it
      $self->{file_hash}->{$filename} = Dicop::Hash->new($filename)
	unless ref $self->{file_hash}->{$filename};
      my $sfh = $self->{file_hash}->{$filename};

      # found correct file, so return success
      return 0 if ($sfh->as_hex() eq $hash);
      output ("Hash still not ok after download.\n") if $self->{debug} > 1;
      output ("Hash should be $hash, but is ", $sfh->as_hex(),"\n") if $self->{debug} > 1;
      }
    } # for all URIs
  # we only arrive here if we couldn't download the file at all
  1;						# failure/mismatch
  }

sub _die_hard
  {
  my $self = shift;
  logger("$self->{logfile}",@_);
  my $txt = shift;
  die("$txt");
  }

sub output
  {
  # print a text. Used by the testsuite to inhibit gibberish

  # allow calling style $self->output()
  shift if $_[0] =~ /^Dicop::/;
  print @_;
  }

sub architecture
  {
  my $self = shift;

  $self->{arch};
  }

sub sub_arch
  {
  my $self = shift;
  
  $self->{cfg}->{sub_arch};
  }

sub full_arch
  {
  my $self = shift;

  my $a = $self->{arch};
  $a .= '-' . $self->{cfg}->{sub_arch} if $self->{cfg}->{sub_arch};
  $a;
  }

1; 

__END__

#############################################################################

=pod

=head1 NAME

Dicop::Client -- a client object

=head1 SYNOPSIS

	use Dicop::Client;

	my $client = new Dicop::Client ('config/client.cfg');

        $client->work();	# never returns unless hard error occurs

=head1 REQUIRES

perl5.004, Dicop::Event, Dicop::Config, Dicop::Item, Dicop::Request, Linux::Cpuinfo,
Dicop::Hash

=head1 EXPORTS

Exports nothing.

=head1 DESCRIPTION

This module represents a client and manages all communication between
servers and client and the client and the workers.

It uses Dicop::Connect for the network connection via HTTP/FTP to
the server or proxy.

=head1 METHODS

=head2 new

Create a client object by using the supplied config file (or uses 
'config/client.cfg' as default.

=head2 work

Main loop. Start working and never return (except in case of fatal errors).

=head2 change_root

	$client->change_root();

Uses chroot() to change the root directory to the given directory from the
configuration file (or command line). Call before L<change_user_and_group>
because chroot() only works for root.
  
=head2 change_user_and_group

	$client->change_user_and_group();

Uses POSIX to change the real user and group id of the process.

=head2 architecture

	print $client->architecture();

Return the name of the base arcitecture the client is running on.
  
=head2 full_arch

	print $client->full_arch();

Return the full arcitecture string (including sub_arch). See also
L<sub_arch>.
  
=head2 sub_arch

	print $client->sub_arch();

Return the sub architecture string. See also L<full_arch>.

=head2 output

	$self->output( "text", "test", "foo");

Prrint a list of texts. Overrided by the testsuite to inhibit unwanted output.

=head2 _get_more_work

Adds another request to the queue, unless we already have a request for work
in there.

=head2 _die_hard

Log an error text to the logfile, and then die finally.

=head2 _break_chunk
  
The server sends us the chunks to work on as a compact string. Ths routine
breaks them down into parts and returns a hash containing the pieces.

=head2 _work_on_chunks

For all the chunks to work on the server sent us, break them down, then start
the worker and insert the result (FAIL, SUCCESS, TIMEOUT or DONE) as request
into the sending queue.

=head2 _store

Add the given request(s) to the list of to-be-sent items (insert it into the
send-queue). The input is a list of Dicop::Requests, or scalars holding
strings, the output the number of requests now in the queue.

=head2 _parse_responses

Parse the server's response into requests, and throw away any garbage/junk.
This also throws away responses with an code lower than 100, as these are only
idle chatter.

The input is an response object from the server, or a scalar (for test suite).

This returns a ref to an array which contains in every element
C<[ response_id, response_code, response_text]>. So for two responses the array
has two entries.

=head2 _parse_responses_for_files

This method walks the list of requests/messages/answers we got from the server,
and extracts each file we will need to work from them. All the files are
entered into a HASH keyed on their filename (to avoid doubles) and the value
is the hash of the file we must download.

=head2 _handle_responses

From list of the server's responses, clear any request from our send list,
that was answered successfully by the server. 

After this, anything that needs to be send again will be in the
send stack, including our authentication, anything other will be deleted.

Chunks of work or test will be added to our todo list, which is than processed
by L<work_on_chunks>.

=head2 _clear_send_queue

After an hard error, we clear the send queue from the requests we tried to
send and then fill it with our auth request and one request for more work.

This ensures that after some hard error we start with a fresh and new list
of requests for the server and forget the old, malformed ones.

Called automatically by L<_handle_responses>.

=head2 _extract_result

	($code,$res,$crc) = $self->_extract_result($rc);

Takes the output of the worker and tries to extract the result, the chunk
CRC (checksum) and stopcode from it. Returns -1 for $code when it doesn't find
a stopcode, and '' as result when there was no result in the output to be
found.

=head2 _start_worker

Given a hash representation of a chunk, start the appropiate worker and let
it work on the chunk. Returns a request-string to be entered into the send
queue and the status code as text.

=head2 _talk_to_server

Adds together all the requests we need to send to the server, including our
authentication request. Then calls L<connect_to_server()>,
L<parse_responses()>, and L<_handle_responses()>.

=head2 _check_file

	if ($self->_check_file($filename,$hash)
	  {
	  print "$file is ok.\n";
	  }
	else
	  {
	  print "$file is not there or outdated.\n";
	  }

This routine checks if we got the required version of a file. If the file is
not there or does not have the proper hash, it will return false.

=head2 _retrieve_files

Given a list of filenames in form of a hash reference, will ask server for
download locations of all the files, then uses L<_download_file> to download
them one by one.

Does not report whether all could be downloaded or not, this needs to be checked
on a file-by-file basis to correctly decide which requests from the server
we can work on and which are missing files - the same file might be missing
for more than one request!.

=head2 _download_file

	$self->_download_file($file,$hash, $uris);

Download a file from a given list of URIs and checks via hash that we got the
right file. Return 0 for success or 1 for error.

=head2 _worker_name

From the architecture name of the client, the worker dir and the worker name
supplied by the server (via the request/chunk), construct the path to the
worker. If a .exe file exists, this will be returned, otherwise just the
executable name as it is.

Returns a list consisting of the path and name of the worker.

=head2 _sleeping
  
When an error occured, or we got no response, or no work, we wait
a time to not overload the server. This routine does log the error,
prints some information and then sleeps.

=head2 _delete_temp_files

Deletes all temporary files that got sent from the server for the current chunk.

Does currently not take into account of we need to work on more than one chunk, so
needs to be called after all chunks have been completed.

=head1 BUGS

None discovered yet.

=head1 AUTHOR

(c) Bundesamt fuer Sicherheit in der Informationstechnik 1998-2006

DiCoP is free software; you can redistribute it and/or modify it under the
terms of the GNU General Public License version 2 as published by the Free
Software Foundation.

See L<http://www.bsi.de/> for more information.

=cut

