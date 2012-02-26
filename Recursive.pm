package Net::FTP::Recursive;

use Net::FTP;
use Carp;
use strict;

our @ISA = qw|Net::FTP|;
our $VERSION = '1.2';

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

  %options = (ParseSub => \&parse_files,
	      @_
	     );    #setup the options

  $ftp->_rget(); #do the real work here

}

sub _rget {

  my($ftp) = @_;

  my(@files) = $options{ParseSub}->($ftp->dir);

  print STDERR join("\n",map { $_->originalLine() } @files),"\n" if $ftp->debug;

  foreach my $file (@files){

    #if it's not a directory we just need to get the file.
    if ( $file->isPlainFile() ) {
      print STDERR "Retrieving " . $file->filename() . "\n" if $ftp->debug;
      $ftp->get( $file->filename() );
    }

    #otherwise, if it's a directory, we have more work to do.
    #this will do depth-first retrieval
    elsif ( $file->isDirectory() ) {

      print STDERR "Making dir: " . $file->filename() . "\n" if $ftp->debug;

      unless ( $options{FlattenTree} ) {
	mkdir $file->filename(), "0755"; #mkdir, ignore errors due to
                                         #pre-existence

	chmod 0755, $file->filename();   # just in case the UMASK in the
                                         # mkdir doesn't work
	chdir $file->filename() or
	  croak('Could not change to the local directory ' . $file->filename() . '!');
      }

      $ftp->cwd( $file->filename() );

      #need to recurse
      print STDERR 'Calling rftp in ', $ftp->pwd, "on ", $file->filename(), "\n" if $ftp->debug;
      $ftp->_rget( );

      #once we've recursed, we'll go back up a dir.
      print STDERR "Returned from rftp in " . $ftp->pwd . ".\n" if $ftp->debug;
      $ftp->cdup;
      chdir ".." unless $options{FlattenTree};

    }

    elsif ( $file->isSymlink() ) {

      if ( $options{SymlinkIgnore} ) {
	print STDERR "Ignoring the symlink ", $file->filename(), ".\n" if $ftp->debug;
      } elsif ( $options{SymlinkCopy} ) {
	$ftp->get( $file->linkName() );
      } elsif ( $options{SymlinkLink}) {
	#we need to make the symlink and that's it.
	symlink $file->linkName(), $file->filename();
      }

    }

  }

}

sub rput{

  my($ftp) = shift;

  %options = (DirCommand => 'ls -la',
	      ParseSub => \&parse_files,
	      @_
	     );    #setup the options

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

  my(@ls);

  @ls = qx[$options{DirCommand}];

  chomp(@ls);

  my @files = $options{ParseSub}->(@ls);

  print STDERR join("\n", map { $_->originalLine() } @files),"\n" if $ftp->debug;

  foreach my $file (@files){

    #if it's a file we just need to put the file

    if ( $file->isPlainFile() ) {
      print STDERR "Sending ", $file->filename(), ".\n" if $ftp->debug;
      $ftp->put( $file->filename() );
    }

    #otherwise, if it's a directory, we have to create the directory
    #on the remote machine, cd to it, then recurse

    elsif ( $file->isDirectory() ) {

      print STDERR "Making dir: ", $file->filename(), "\n" if $ftp->debug;

      unless ( $options{FlattenTree} ) {
	$ftp->mkdir( $file->filename() ) or
	  croak ('Could not make remote directory ' . $ftp->pwd
		 . '/' . $file->filename() . '!');

	$ftp->cwd( $file->filename() );
      }


      chdir $file->filename() or
	croak ("Could not change to the local directory "
	       . $file->filename . "!");

      print STDERR "Calling rput in ", $ftp->pwd, "\n" if $ftp->debug;
      $ftp->_rput( );

      #once we've recursed, we'll go back up a dir.
      print STDERR "Returned from rftp in ",
	           $file->filename(), ".\n" if $ftp->debug;

      $ftp->cdup unless $options{FlattenTree};
      chdir "..";

    }

    #if it's a symlink, there's nothing we can do with it.

    elsif ( $file->isSymlink() ) {

      if ( $options{SymlinkIgnore} ) {
	print STDERR "Not doing anything to ", $file->filename(), " as it is a link.\n" if $ftp->debug;
      } elsif ( $options{SymlinkCopy} ) {
	$ftp->put( $file->linkName() );
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

    my($file); #reinitialize var

    my @fields = $line =~ /^
                            (\S+)\s+ #permissions %p
                            (\d+)\s+ #link count %lc
                            (\w+)\s+ #user owner %u
                            (\w+)\s+ #group owner %g
                            (\d+)\s+ #size %s
                            (\w+\s+\w+\s+\S+)\s+ #last modification date %d
                            (.+?)\s* #filename %f
                            (?:->\s*(.+))? #optional link part %l
                           $
                          /x;

    my($perms) = ($1);

    next if $fields[6] =~ /^\.{1,2}$/;

    if ($perms =~/^-/){
      $file = new Net::FTP::Recursive::File(IsPlainFile => 1,
					    OriginalLine => $line,
					    Fields => [@fields]);
    } elsif ($perms =~ /^d/) {
      $file = new Net::FTP::Recursive::File(IsDirectory => 1,
					    OriginalLine => $line,
					    Fields => [@fields]);
    } elsif ($perms =~/^l/) {
      $file = new Net::FTP::Recursive::File(IsSymlink => 1,
					    OriginalLine => $line,
					    Fields => [@fields]);
    }

    push(@to_return, $file);

  }

  return(@to_return);

}

sub rdir{

  my($ftp) = shift;

  %options = (ParseSub => \&parse_files,
	      OutputFormat => '%p %lc %u %g %s %d %f %l',
	      @_
	     );    #setup the options

  return unless $options{Filehandle};

  $ftp->_rdir;

}

sub _rdir{

  my($ftp) = shift;

  my $dir = $ftp->pwd;

  my(@ls) = $ftp->dir;

  my(@files) = $options{ParseSub}->( @ls );

  print STDERR join("\n",map { $_->originalLine() } @files),"\n" if $ftp->debug;

  my(@dirs);
  my $fh = $options{Filehandle};
  print $fh $ftp->pwd, ":\n" unless $options{FilenameOnly};

  foreach my $file (@files) {

    #if it's a directory, we need to save the name for later

    if ( $file->isDirectory() ) {
        push @dirs, $file->filename();
    }

    if( $options{FilenameOnly} ){
	print $fh $dir, '/', $file->filename(),"\n";
    } else {
	print $fh $file->originalLine(), "\n";
    }

  }

  @files = undef; #mark this for cleanup, it might matter since we're recursing

  print $fh "\n" unless $options{FilenameOnly};


  foreach my $dir (@dirs){

    $ftp->cwd( $dir );

    print STDERR "Calling rdir in ", $ftp->pwd, "\n" if $ftp->debug;
    $ftp->_rdir( );

    #once we've recursed, we'll go back up a dir.
    print STDERR "Returned from rdir in " . $dir . ".\n" if $ftp->debug;
    $ftp->cdup;
  }

}

sub rls{
  my $ftp = shift;
  $ftp->rdir(@_, FilenameOnly => 1);
}

package Net::FTP::Recursive::File;

our @ISA = ();

sub new{

  my $pkg = shift;

  my $self = bless {@_}, $pkg;

}

sub originalLine{
  return $_[0]->{OriginalLine};
}

sub filename{
  return $_[0]->{Fields}[6];
}

sub linkName{
  return $_[0]->{Fields}[7];
}

sub isSymlink{
  return $_[0]->{IsSymlink};
}

sub isDirectory{
  return $_[0]->{IsDirectory};
}

sub isPlainFile{
  return $_[0]->{IsPlainFile};
}

sub fields{
  return $_[0]->{Fields};
}

1;

__END__

=head1 NAME

Net::FTP::Recursive - Recursive FTP Client class

=head1 SYNOPSIS

    use Net::FTP::Recursive;

    $ftp = Net::FTP::Recursive->new("some.host.name", Debug => 0);
    $ftp->login("anonymous",'me@here.there');
    $ftp->cwd('/pub');
    $ftp->rget( ParseSub => \&yoursub );
    $ftp->quit;

=head1 DESCRIPTION

C<Net::FTP::Recursive> is a class built on top of the Net::FTP package
that implements recursive get and put methods for the retrieval and
sending of entire directory structures.

This module's default behavior is such that the remote ftp
server should understand the "dir" command and return
UNIX-style directory listings.  If you'd like to provide
your own function for parsing the data retrieved from this
command (in case the ftp server does not understand the
"dir" command), all you need do is provide a function to one
of the Recursive method calls.  This function will take the
output from the "dir" command (as a list of lines) and
should return a list of Net::FTP::Recursive::File objects.
This module is described below.

When the C<Debug> flag is used with the C<Net::FTP> object, the
C<Recursive> package will print some messages to C<STDERR>.

=head1 CONSTRUCTOR

=over

=item new (HOST [,OPTIONS])

A call to the new method to create a new
C<Net::FTP::Recursive> object just calls the C<Net::FTP> new
method.  Please refer to the C<Net::FTP> documentation for
more information.

=back

=head1 METHODS

=over


=item rget ( [ParseSub =>\&yoursub] [FlattenTree => 1] )

The recursive get method call.  This will recursively
retrieve the ftp object's current working directory and its
contents into the local current working directory.

This will also take an optional argument that will control what
happens when a symbolic link is encountered on the ftp
server.  The default is to ignore the symlink, but you can
control the behavior by passing one of these arguments to
the rget call (ie, $ftp->rget(SymlinkIgnore => 1)):

=over

=item SymlinkIgnore - disregards symlinks

=item SymlinkCopy - copies the link target from the server to the client (if accessible)

=item SymlinkLink - creates the link on the client.

=back

The C<FlattenTree> optional argument will retrieve all of
the files from the remote directory structure and place them
in the current local directory.


=item rput ( [ParseSub => \&yoursub] [DirCommand => $cmd] [FlattenTree => 1])

The recursive put method call.  This will recursively send the local
current working directory and its contents to the ftp object's current
working directory.

This method will take an optional set of arguments to tell
it what the local directory listing command will be.  By
default, this is "ls -al".  If you change the behavior
through this argument, you probably also need to provide a
ParseSub, as described above.

This will take an optional argument that will control what
happens when a symbolic link is encountered on the ftp
server.  The default is to ignore the symlink, but you can
control the behavior by passing one of these arguments to
the rput call (ie, $ftp->rput(SymlinkIgnore => 1)):

=over

=item SymlinkIgnore - disregards symlinks

=item SymlinkCopy - will copy the link target from the client to the server.

=back

The C<FlattenTree> optional argument will send all of
the files from the local directory structure and place them
in the current remote directory.

=item rdir ( Filehandle => $fh [, FilenameOnly => 1 ] [, ParseSub => \&yoursub ] )

The recursive dir method call.  This will recursively retrieve
directory contents from the server in a breadth-first fashion.

The method needs to be passed a filehandle to print to.  The method
call just does a C<print $fh>, so as long as this call can succeed
with whatever you pass to this function, it'll work.

The second, optional argument, is to retrieve only the filenames
(including path information).  The default is to display all of the
information returned from the $ftp-dir call.



=item rls ( Filehandle => $fh [, ParseSub => \&yoursub ] )

The recursive ls method call.  This will recursively
retrieve directory contents from the server in a
breadth-firth fashion.  This is equivalent to calling
C<$ftp->rdir( Filehandle => $fh, FilenameOnly => 1 )>.



=head1 Net::FTP::Recursive::File

This is a helper class that encapsulates the data
representing one file in a directory listing.

=head1 METHODS

=over

=item new ( )

This method creates the File object.  It should be passed
several parameters.  It should always be passed:

=over

=item OriginalLine => $line

=item Fields => \@fields

=back

And it should also be passed one (and only one) of:

=over

=item IsPlainFile => 1

=item IsDirectory => 1

=item IsSymlink => 1

=back

OriginalLine should provide the original line from the
output of a directory listing.

Fields should provide an 8 element list that supplies
information about the file.  The fields, in order, should
be:

=over

=item Permissions

=item Link Count

=item User Owner

=item Group Owner

=item Size

=item Last Modification Date/Time

=item Filename

=item Link Target

=back

The C<IsPlainFile>, C<IsDirectory>, and C<IsSymlink> fields
need to be supplied so that for the output on your
particular system, your code (in the ParseSub) can determine
which type of file it is so that the Recursive calls can
take the appropriate action for that file.  Only one of
these three fields should be set to a "true" value.

=back

=head1 TODO LIST

=over

=item Allow for formats to be given for output on rdir/rls.

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

