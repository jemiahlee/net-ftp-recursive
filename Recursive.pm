package Net::FTP::Recursive;

use Net::FTP;
use strict;

our @ISA = qw|Net::FTP|;
our $VERSION = '1.0';

###################################################################
# Constants for the different file types
###################################################################
our $file_type = 1;
our $dir_type = 2;
our $link_type = 3;

our %options;

#------------------------------------------------------------------
# - cd to directory, lcd to directory
# - look at each file, determine if it should be d/l'ed
#     - if so, download files, put timestamp into hash
#
# - foreach directory, look up in hash to see if it is in there
#    - if not, create it
#    - in either case, call function recursively.
#    - cd .., lcd ..
#
# -----------------------------------------------------------------

sub rget{

  my($ftp) = shift;

  %options = @_; #setup the options

  $ftp->_rget(); #do the real work here

}

sub _rget {

  my($ftp) = @_;

  my(@lines) = parse_files($ftp->dir);

  print STDERR join("\n",map {join " ", keys %$_ } @lines),"\n" if $ftp->debug;

  foreach my $entry (@lines){

    #if it's not a directory we just need to get the file.
    if ( $entry->{type} == $file_type ) {
      print STDERR "Retrieving $entry->{filename}\n" if $ftp->debug;
      $ftp->get($entry->{filename});

    }

    #otherwise, if it's a directory, we have more work to do.
    #this will do depth-first retrieval
    elsif ($entry->{type} == $dir_type) {

      print STDERR "Making dir: $entry->{filename}\n" if $ftp->debug;

      mkdir $entry->{filename},"0755" and #mkdir, ignore errors due to
	                           #pre-existence

      chmod 0755, $entry->{filename}; # just in case the UMASK in the
                               # mkdir doesn't work

      chdir $entry->{filename} or
	die('Could not change to the local directory '
	     . $entry->{filename} . '!');

      $ftp->cwd($entry->{filename});

      #need to recurse
      print STDERR 'Calling rftp in ' . $ftp->pwd . "on $entry->{filename}\n" if $ftp->debug;
      $ftp->_rget( );

      #once we've recursed, we'll go back up a dir.
      print STDERR "Returned from rftp in " . $ftp->pwd . ".\n" if $ftp->debug;
      $ftp->cdup;
      chdir "..";

    }

    elsif ($entry->{type} == $link_type) {

      if (not %options or $options{symlink_ignore}) {
	print STDERR "Ignoring the symlink $entry->{filename}.\n" 
	  if $ftp->debug;
      } elsif ( $options{symlink_copy} ) {
	$ftp->get($entry->{link_target});
      } elsif ( $options{symlink_link}) {
	#we need to make the symlink and that's it.
	symlink $entry->{link_target}, $entry->{filename};
      }

    }

  }

}

sub rput{

  my($ftp) = shift;

  %options = @_; #setup the options

  $ftp->_rput(); #do the real work here

}

#------------------------------------------------------------------
# - make the directory on the remote host
# - cd to directory, lcd to directory
# - foreach directory, call the function recursively
# - cd .., lcd ..
# -----------------------------------------------------------------

sub _rput {

  my($ftp) = @_;

  my(@ls) = `ls -la`;
  chomp(@ls);

  my(@lines) = parse_files( @ls );

  print STDERR join("\n",map { join " ", keys %$_ } @lines),"\n" if $ftp->debug;

  foreach my $entry (@lines){

    #if it's a file we just need to put the file

    if ( $entry->{type} == $file_type ) {

      print STDERR "Sending $entry->{filename}.\n" if $ftp->debug;
      $ftp->put($entry->{filename});

    }

    #otherwise, if it's a directory, we have to create the directory
    #on the remote machine, cd to it, then recurse

    elsif ($entry->{type} == $dir_type) {

      print STDERR "Making dir: $entry->{filename}\n" if $ftp->debug;

      $ftp->mkdir($entry->{filename}) or 
	die ('Could not make remote directory ' . $ftp->pwd 
	      . '/' . $entry->{filename} . '!');

      $ftp->cwd($entry->{filename});

      chdir $entry->{filename} or 
	die ("Could not change to the local directory $entry->{filename}!");

      print STDERR "Calling rput in ", $ftp->pwd, "\n" if $ftp->debug;
      $ftp->_rput( );

      #once we've recursed, we'll go back up a dir.
      print STDERR "Returned from rftp in $entry->{filename}.\n" if $ftp->debug;
      $ftp->cdup;
      chdir "..";

    }

    #if it's a symlink, there's nothing we can do with it.

    elsif ($entry->{type} == $link_type) {

      if ( $options{symlink_ignore} ) {
	print STDERR "Not doing anything to $entry->{filename} as it is a link.\n" if $ftp->debug;
      } elsif ( $options{symlink_copy} ) {
	$ftp->put($entry->{link_target});
      }

    }

  }

}

#-------------------------------------------------------------------#
# Should look at all of the output from the current dir and parse
# through and extract the filename, date, size, and whether it is a
# directory or not
#
# The date should also have a time, so that if the script needs to be
# run several times in one day, it will grab any files that changed
# that day.
#-------------------------------------------------------------------#

sub parse_files {

  shift; #throw away the first line, it should be a "total" line

  my(@to_return);

  foreach my $line (@_) {

    next unless $line =~ /^[-dl]/;

    my($linkname, $type); #reinitialize vars

    my($perms,$filename) = (split(/\s+/, $line,9))[0,8];

    next if $filename =~ /^\.{1,2}$/;

    if ($perms =~/^-/){
      $type = $file_type;
    } elsif ($perms =~ /^d/) {
      $type = $dir_type;
    } elsif ($perms =~/^l/) {
      $type = $link_type;
      ($filename,$linkname) = $filename =~ m#(.*?)\s*->\s*(.*)$#;
    }

    push(@to_return, {
		      filename => $filename,
		      type => $type,
		      link_target => $linkname
		     }
	);

  }

  return(@to_return);

}

1;

__END__

=head1 NAME

Net::FTP::Recursive - Recursive FTP Client class

=head1 SYNOPSIS

    use Net::FTP::Recursive;

    $ftp = New::FTP::Recursive->new("some.host.name", Debug => 0);
    $ftp->login("anonymous",'me@here.there');
    $ftp->cwd('/pub');
    $ftp->rget();
    $ftp->quit;

=head1 DESCRIPTION

C<Net::FTP::Recursive> is a class built on top of the Net::FTP package
that implements recursive get and put methods for the retrieval and
sending of entire directory structures.

This module will work only when the remote ftp server and
the local client understand the "ls" command and return
UNIX-style directory listings.  It is planned that in the
future, this will be a configurable part of the module.

When the C<Debug> flag is used with the C<Net::FTP> object, the
C<Recursive> package will print some messages to C<STDERR>.

=head1 CONSTRUCTOR

=over 4

=item new (HOST [,OPTIONS])

A call to the new method to create a new
C<Net::FTP::Recursive> object just calls the C<Net::FTP> new
method.  Please refer to the C<Net::FTP> documentation for
more information.

=back

=head1 METHODS

=over 4

=item rget ( )

The recursive get function call.  This will recursively retrieve the
ftp object's current working directory and its contents into the local
current working directory.

This will take an optional argument that will control what
happens when a symbolic link is encountered on the ftp
server.  The default is to ignore the symlink, but you can
control the behavior by passing one of these arguments to
the rget call (ie, $ftp->rget(symlink_ignore => 1)):

=over 12

=item symlink_ignore - disregards symlinks

=item symlink_copy - copies the link target from the server to the client (if accessible)

=item symlink_link - creates the link on the client.

=back

=item rput ( )

The recursive put function call.  This will recursively send the local
current working directory and its contents to the ftp object's current
working directory.

This will take an optional argument that will control what
happens when a symbolic link is encountered on the ftp
server.  The default is to ignore the symlink, but you can
control the behavior by passing one of these arguments to
the rput call (ie, $ftp->rput(symlink_ignore => 1)):

=over 12

=item symlink_ignore - disregards symlinks

=item symlink_copy - will copy the link target from the client to the server.

=back

=back

=head1 TODO LIST

=over 4

=item Make the "ls" command configurable

=item Make the parsing of the "ls" output configurable

=back

=head1 REPORTING BUGS

When reporting bugs, please provide as much information as possible.
A script that exhibits the bug would also be helpful, as well as
output with the "Debug => 1" flag turned on in the FTP object.

=head1 AUTHOR

Jeremiah Lee <texasjdl@yahoo.com>

=head1 SEE ALSO

L<Net::FTP>

L<Net::Cmd>

ftp(1), ftpd(8), RFC 959

=head1 CREDITS

Andrew Winkler - for various input into the module.

=head1 COPYRIGHT

Copyright (c) 2001-2003 Jeremiah Lee.

This program is free software; you may redistribute it and/or
modify it under the same terms as Perl itself.

=cut

