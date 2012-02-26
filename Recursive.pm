package Net::FTP::Recursive;

use Net::FTP;
use strict;
use warnings;

our @ISA = qw|Net::FTP|;
our $VERSION = '1.5';

###################################################################
# Constants for the different file types
###################################################################
our $file_type = 1;
our $dir_type = 2;
our $link_type = 3;

our %options;
our %filesSeen;
our %dirsSeen;
our %link_map;

#------------------------------------------------------------------
# - cd to directory, lcd to directory
# - grab all files, process symlinks according to options
#
# - foreach directory
#    - create it unless options say to flatten
#    - call function recursively.
#    - cd .. unless options say to flatten
#    - lcd ..
#
# ----------------------------------------------------------------- 

sub rget{

  my($ftp) = shift;

  %options = (ParseSub => \&parse_files,
	      InitialDir => $ftp->pwd,
	      @_
	     );    #setup the options

  %filesSeen = ();

  chomp(my $pwd = `pwd`);

  %dirsSeen = ( $ftp->pwd => $pwd );

  %link_map = ();

  $ftp->_rget(); #do the real work here

  %filesSeen = ();
  %dirsSeen = ();
  %link_map = ();

  if ( $options{RemoveRemoteFiles} ) {
    $ftp->_rdelete;
  }
}

sub _rget {

  my($ftp) = shift;
  my @dirs;
  my $get_success;
  my(@files) = $options{ParseSub}->($ftp->dir);

  print STDERR join("\n",map { $_->originalLine() } @files),"\n" if $ftp->debug;

  foreach my $file (@files){

    #if it's not a directory we just need to get the file.
    if ( $file->isPlainFile() ) {
      my $filename = $file->filename();

      if ( $options{FlattenTree} and $filesSeen{$filename} ) {
	print STDERR "Retrieving $filename as $filename.$filesSeen{$filename}.\n" if $ftp->debug;
	$get_success = $ftp->get( $filename, "$filename.$filesSeen{$filename}" );
      } else {
	print STDERR "Retrieving $filename.\n" if $ftp->debug;
	$get_success = $ftp->get( $filename );
      }

      $filesSeen{$filename}++ if $options{FlattenTree};

      if ( not $get_success and $ftp->debug ) {
	print STDERR "Was unable to retrieve $filename from server!\n";
      }
    }

    #otherwise, if it's a directory, we have more work to do.
    elsif ( $file->isDirectory() ) {
      push @dirs, $file;
    }

    elsif ( $file->isSymlink() ) {

      #These are broken out as individual if statements due to some
      #messiness with symlinks (specifically, we have to do some extra
      #work to try to cd into a symlink if the SymlinkFollow option is
      #set.  This can cause problems if a deleted directory is linked
      #to

      if ( $options{SymlinkIgnore} ) {
	print STDERR "Ignoring the symlink ", $file->filename(), ".\n" if $ftp->debug;
	next;
      }

      my $ftp_pwd = $ftp->pwd;

      #need the SymlinkFollow option to be set. if it is set, then we
      if ( $options{SymlinkFollow} and
	   ( $ftp->cwd($file->filename()) and $ftp->cwd($ftp_pwd) )
	 ){

	#default to deleting the file if the RemoveRemoteFiles option
	#is set
	my $get_success = 1;

	#this is all code to check for cycles.  if there is
	#a cycle, what we try to do is create a symlink to
	#the place on the local system where we're storing
	#the dir

	print STDERR "Got to the cycle-checking code!\n";

	my $link_path = $file->linkname();
	my $local_path;

	#make a relative path an absolute path
	my $remote_pwd = path_resolve( $link_path,
				    $ftp_pwd,
				    $file->filename );

	print STDERR 'In ', $ftp_pwd, ' resolved \'',
	      $file->linkname(), "' to '$remote_pwd'\n" if $ftp->debug;

	#need to see if the $dirsSeen map has already been set up.  if
	#that's not set, we try to cd into the directory and then cd
	#back out.  in case the server isn't keeping track of where
	#we actually came from, we manually specify the path to cd to.

	#using this in the case statement below
	chomp(my $pwd = `pwd`);

	#now compare the absolute path with the path that we
	#started with to see if it will be grabbed at some
	#point during the rget or check to see if it was
	#already grabbed

	#If we've already grabbed the directory that was
	#linked to, we create a symlink to the directory on
	#the local system.  This will be a relative path to
	#the directory we've created locally.

	if ( not $options{FlattenTree} and $dirsSeen{$remote_pwd}){
	  print STDERR "1st case!\n";
	  my $tmp = convert_to_relative($pwd . '/' . $file->filename(),
					$dirsSeen{$remote_pwd});
	  print STDERR 'Symlinking \'', $file->filename, "' to '$tmp'.\n" if $ftp->debug;
	  symlink $tmp, $file->filename();
	}

	# If the directory that was linked to is part of the
	# subtree from where we started the rget, we just
	# create the relative path and link to that
	elsif ( not $options{FlattenTree} and 
		($local_path = $remote_pwd) =~ s#
                                   ^
                                   \Q$options{InitialDir}\E
                                  #$dirsSeen{$options{InitialDir}}#x
	      ) {
	  print STDERR "2nd case!\n";
	  my $tmp = convert_to_relative($pwd . '/' . $file->filename(),
					$local_path );
	  print STDERR 'Symlinking \'', $file->filename(),
	    "' to '$tmp'.\n" if $ftp->debug;
	  symlink $tmp, $file->filename();
	}

	# Otherwise we need to grab the directory and put
	# the info in a hash in case there is another link
	# to this directory
	else {

	  print STDERR "3rd case!\n";
	  push @dirs, $file;

	  $dirsSeen{$remote_pwd} = $pwd . '/' . $file->filename();

	}

	#since we did something with this file, go to the next one.
	next;

      }

      if ( $options{SymlinkLink}) {
	#we need to make the symlink and that's it.
	symlink $file->linkname(), $file->filename();
	next;
      }

      #need to make sure the SymlinkCopy option is set and
      #that it's not a directory (since we could reach here
      #without SymlinkFollow being set, it's possible that
      #it is a link to a directory).
      if ( $options{SymlinkCopy} ) { #if it's not and
	                                    #SymlinkCopy is set,
                                            #we'll copy the file
	my $filename = $file->filename();

	#symlink to non-directory.  need to grab it and
	#make sure the filename does not collide

	if ( $options{FlattenTree} and $filesSeen{$filename}) {
	  print STDERR "Retrieving $filename as $filename.$filesSeen{$filename}.\n" if $ftp->debug;
	  $get_success = $ftp->get( $filename, "$filename.$filesSeen{$filename}" );
	} else {
	  print STDERR "Retrieving $filename.\n" if $ftp->debug;
	  $get_success = $ftp->get( $filename );
	}

	$filesSeen{$filename}++;

      }

    } # end of if($file->isSymlink())
  }

  #this will do depth-first retrieval
  foreach my $file (@dirs) {

    #in case we didn't have permissions to cd into that
    #directory - relying on the return code from ftp
    unless ( $ftp->cwd( $file->filename() ) ){
      print STDERR 'Was unable to cd to ', $file->filename,
	", skipping!\n" if $ftp->debug;
      next;
    }

    unless ( $options{FlattenTree} ) {
      print STDERR "Making dir: " . $file->filename() . "\n" if $ftp->debug;

      mkdir $file->filename(), "0755"; #mkdir, ignore errors due to
                                       #pre-existence

      chmod 0755, $file->filename();   # just in case the UMASK in the
                                         # mkdir doesn't work
      unless ( chdir $file->filename() ) {
	print STDERR 'Could not change to the local directory ',
	  $file->filename(), "!\n" if $ftp->debug;
	$ftp->cdup;
	next;
      }
    }

    #need to recurse
    print STDERR 'Calling rget in ', $ftp->pwd, "\n" if $ftp->debug;
    $ftp->_rget( );

    #once we've recursed, we'll go back up a dir.
    print STDERR "Returned from rget in " . $ftp->pwd . ".\n" if $ftp->debug;
    $ftp->cdup;
    chdir ".." unless $options{FlattenTree};

  }

}

sub rput{

  my($ftp) = shift;

  %options = (DirCommand => 'ls -la',
	      ParseSub => \&parse_files,
	      @_
	     );    #setup the options

  %filesSeen = ();
  %dirsSeen = ();

  $ftp->_rput(); #do the real work here

  %dirsSeen = ();
  %filesSeen = ();
}

#------------------------------------------------------------------
# - make the directory on the remote host
# - cd to directory, lcd to directory
# - foreach directory, call the function recursively
# - cd .., lcd ..
# -----------------------------------------------------------------

sub _rput {

  my($ftp) = @_;

  my(@ls, @dirs);

  @ls = qx[$options{DirCommand}];

  chomp(@ls);

  my @files = $options{ParseSub}->(@ls);

  print STDERR join("\n", map { $_->originalLine() } @files),"\n" if $ftp->debug;

  foreach my $file (@files){

    #if it's a file we just need to put the file

    if ( $file->isPlainFile() ) {
      my $filename = $file->filename(); #we're gonna need it a lot here

      #we're going to check for filename conflicts here if
      #the user has opted to flatten out the tree
      if ( $options{FlattenTree} and $filesSeen{$filename} ) {
	print STDERR "Sending $filename as $filename.$filesSeen{$filename}.\n" if $ftp->debug;
	$ftp->put( $filename, "$filename.$filesSeen{$filename}");
      } else {
	print STDERR "Sending $filename.\n" if $ftp->debug;
	$ftp->put( $filename );
      }

      $filesSeen{$filename}++ if $options{FlattenTree};

      if ( $options{RemoveLocalFiles} ) {
	print STDERR 'Removing ', $file->filename(), " from the local system.\n" if $ftp->debug;
	unlink $file->filename();
      }

    }

    #otherwise, if it's a directory, we have to create the directory
    #on the remote machine, cd to it, then recurse

    elsif ( $file->isDirectory() ) {
      push @dirs, $file;
    }

    #if it's a symlink, there's nothing we can do with it.

    elsif ( $file->isSymlink() ) {

      if ( $options{SymlinkIgnore} ) {
	print STDERR 'Not doing anything to ', $file->filename(),
	  " as it is a link.\n" if $ftp->debug;
	if ( $options{RemoveLocalFiles}  ) {
	  print STDERR 'Removing ', $file->filename(), " from the local system.\n" if $ftp->debug;
	  unlink $file->filename();
	}

      } else {

	if ( -f $file->filename() and $options{SymlinkCopy} ) {
	  my $filename = $file->filename();
	  if ( $options{FlattenTree} and $filesSeen{$filename}) {
	    print STDERR "Sending $filename as $filename.$filesSeen{$filename}.\n" if $ftp->debug;
	    $ftp->put( $filename, "$filename.$filesSeen{$filename}" );
	  } else {
	    print STDERR "Sending $filename.\n" if $ftp->debug;
	    $ftp->put( $filename );
	  }
	  $filesSeen{$filename}++;

	  if ( $options{RemoveLocalFiles}  ) {
	    print STDERR 'Removing ', $file->filename(), " from the local system.\n" if $ftp->debug;
	    unlink $file->filename();
	  }

	} elsif ( -d $file->filename() and $options{SymlinkFollow} ) {

	  #Check to see if that 

	  chomp(my $pwd = `pwd`);

	  my $abs_path = path_resolve( $file->linkname(),
				       $pwd,
				       $file->filename()
				     );

	  #if it's already been seen (the real dir), then we
	  #just want to go to the next file, optionally
	  #deleting the symlink
	  if ( $dirsSeen{$abs_path}++ ){
	    if ( $options{RemoveLocalFiles}  ) {
	      print STDERR 'Removing ', $file->filename(), " from the local system.\n" if $ftp->debug;
	      unlink $file->filename();
	    }
	    next;
	  }

	  #then it's a directory that we hasn't been seen, we
	  #need to add it to the list of directories to grab
	  push @dirs, $file;
	}
      }

    }

  }


  foreach my $file (@dirs) {

    #unfortunately, perl doesn't seem to keep track of
    #symlinks very well (at least on my version/platform),
    #so we'll use an absolute path to chdir at the end.

    #we'll use this in the loop if we follow a symlink
    my $local_dir;
    if ( $file->isSymlink() ) {
      $local_dir = `pwd`;
      chomp $local_dir;
    }

    unless ( chdir $file->filename() ) {
      print STDERR 'Could not change to the local directory ',
	$file->filename(), "!\n" if $ftp->debug;
      next;
    }

    unless ( $options{FlattenTree} ) {
      print STDERR "Making dir: ", $file->filename(), "\n" if $ftp->debug;

      $ftp->mkdir( $file->filename() ) or
	print STDERR 'Could not make remote directory ', $ftp->pwd,
	  '/', $file->filename(), "!\n" if $ftp->debug;

      unless ( $ftp->cwd($file->filename()) ){

	#in case we didn't have permissions to cd into that
	#directory

	print STDERR 'Could not change dir to ', $file->filename,
	  "on remote server!\n" if $ftp->debug;
	if ( $file->isSymlink() ) {
	  chdir $local_dir;
	} else {
	  chdir '..';
	}
	next;
      }

    }

    #do this here rather than up above so that we don't have
    #to worry about resetting it if we 'next' the loop
    my $remove;
    if ( $file->isSymlink() ) {
      $remove = $options{RemoveLocalFiles};
      $options{RemoveLocalFiles} = 0;
    }

    print STDERR "Calling rput in ", $ftp->pwd, "\n" if $ftp->debug;
    $ftp->_rput( );

    #once we've recursed, we'll go back up a dir.
    print STDERR 'Returned from rput in ',
      $file->filename(), ".\n" if $ftp->debug;

    $ftp->cdup unless $options{FlattenTree};

    if ( $file->isSymlink() ) {
      chdir $local_dir;

      #reset the remove flag.  if we were already recursed
      #into a symlink, this should still be 0
      $options{RemoveLocalFiles} = $remove;

      if ( $options{RemoveLocalFiles} ) {
	print STDERR 'Removing ', $file->filename(), " from the local system.\n" if $ftp->debug;
	unlink $file->filename();
      }

    } else {
      chdir '..';
      if ( $options{RemoveLocalFiles} ) {
	print STDERR 'Removing ', $file->filename(), " from the local system.\n" if $ftp->debug;
	rmdir $file->filename();
      }
    }

  }

}


sub rdir{

  my($ftp) = shift;

  %options = (ParseSub => \&parse_files,
	      OutputFormat => '%p %lc %u %g %s %d %f %l',
	      @_
	     );    #setup the options

  return unless $options{Filehandle};

  %dirsSeen = (); #just make sure it's empty
  %link_map = ();

  $ftp->_rdir;

  %link_map = ();
  %dirsSeen = (); #empty it for the next use

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
        push @dirs, $file;
    }

    my $ftp_pwd = $ftp->pwd;
    if ( $options{SymlinkFollow} and $file->isSymlink ) {
      if ( $ftp->cwd($file->filename()) ) {
	$ftp->cwd( $ftp_pwd );

	#this is all code to check for cycles.  if there is
	#a cycle, what we try to do is create a symlink to
	#the place on the local system where we're storing
	#the dir

	my $remote_pwd = path_resolve(
				      $file->linkname(),
				      $ftp_pwd,
				      $file->filename()
				     );

	print STDERR 'In ', $ftp->pwd, ' resolved \'',
	      $file->linkname(), "' to '$remote_pwd'\n" if $ftp->debug;

	push @dirs, $file and next unless $dirsSeen{$remote_pwd}++;

	# if we have already seen it, we'll just print it
      }
    }

    if( $options{FilenameOnly} ){
	print $fh $dir, '/', $file->filename(),"\n";
    } else {
	print $fh $file->originalLine(), "\n";
    }

  }

  @files = undef; #mark this for cleanup, it might matter
                  #(save memory) since we're recursing

  print $fh "\n" unless $options{FilenameOnly};


  foreach my $file (@dirs){

    #in case we didn't have permissions to cd into that
    #directory
    unless ( $ftp->cwd($file->filename()) ){
      print STDERR 'Could not change dir to ', $file->filename(), "!\n" if $ftp->debug;
      next;
    }

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

#---------------------------------------------------------------
# CD to directory
# Recurse through all subdirectories and delete everything
#---------------------------------------------------------------

sub rdelete {

   my($ftp) = shift;

   %options = (ParseSub => \&parse_files,
               @_
              );    #setup the options

   $ftp->_rdelete(); #do the real work here

}

sub _rdelete {

   my $ftp = shift;

   my @dirs;

   my(@files) = $options{ParseSub}->($ftp->dir);

   print STDERR join("\n",map { $_->originalLine() } @files),"\n" if 
$ftp->debug;

   foreach my $file (@files){

     #just delete plain files and symlinks
     if ( $file->isPlainFile() or $file->isSymlink() ) {
       my $filename = $file->filename();
       $ftp->delete($filename);
     }

     #otherwise, if it's a directory, we have more work to do.
     elsif ( $file->isDirectory() ) {
       push @dirs, $file;
     }
   }

   #this will do depth-first delete
   foreach my $file (@dirs) {

     #in case we didn't have permissions to cd into that
     #directory
     unless ( $ftp->cwd( $file->filename() ) ){
       print STDERR 'Could not change dir to ',
	 $file->filename(), "!\n" if $ftp->debug;
       next;
     }

     #need to recurse
     print STDERR 'Calling _rdelete in ', $ftp->pwd, "\n" if $ftp->debug;
     $ftp->_rdelete( );

     #once we've recursed, we'll go back up a dir.
     print STDERR "Returned from _rdelete in " . $ftp->pwd . ".\n" if 
$ftp->debug;
     $ftp->cdup;
     ##now delete the directory we just came out of
     $ftp->rmdir($file->filename());
   }

}

=for comment

  This subroutine takes a path and converts the '.' and
  '..' parts of it to make it into a proper absolute path.

=cut

sub path_resolve{
  my($link_path, $pwd, $filename) = @_;
  my $remote_pwd; #value to return

  #this case is so that if we have gotten to this
  #symlink through another symlink, we can actually
  #retrieve the correct files (make the correct
  #symlink, whichever)

  if ( $link_map{$pwd} and $link_path !~ m#^/# ) {
    $remote_pwd = $link_map{$pwd} . '/' . $link_path;
  }

  # if it was an absolute path, just make sure there
  # aren't any . or .. in it
  elsif ( $link_path =~ m#^/# ) {
    $remote_pwd = $link_path;
  }

  #otherwise, it was a relative path and we need to
  #prepend the current working directory onto it and
  #then eliminate any .. or . that are present
  else {
    $remote_pwd = $pwd;
    $remote_pwd =~ s#(?<!/)$#/#;
    $remote_pwd .= $link_path;
  }

  #Collapse the resulting path if it has . or .. in it.  The
  #while loop is needed to make it start over after each
  #match (as it will need to go back for parts of the
  #regex).  It's probably possible to write a regex to do it
  #without the while loop, but I don't think that making it
  #less readable is a good idea.  :)

  while ( $remote_pwd =~ s#(^|/)\.(/|$)#/# ) {}
  while ( $remote_pwd =~ s#(/[^/]+)?/\.\.(/|$)#/# ){}

  #the %link_map will store as keys the absolute paths
  #to the links and the values will be the "real"
  #absolute paths to those locations (to take care of
  #../-type links
  $pwd =~ s#(?<!/)$#/#; #make sure there's a / on the end
  $link_map{$pwd . $filename} = $remote_pwd;

  $remote_pwd; #return the result

}

=for comment

  This subroutine takes two absolute paths and basically
  'links' them together.  The idea is that all of the paths
  that are created for the symlinks should be relative
  paths.  This is the sub that does that.

  There are essentially 6 cases:

    -Different root hierarchy:
        /tmp/testdata/blah -> /usr/local/bin/blah
    -Current directory:
        /tmp/testdata/blah -> /tmp/testdata
    -A file in the current directory:
        /tmp/testdata/blah -> /tmp/testdata/otherblah
    -Lower in same hierarchy:
        /tmp/testdata/blah -> /tmp/testdata/dir/otherblah
    -A higher directory along the same path (part of link abs path) :
        /tmp/testdata/dir/dir2/otherblah -> /tmp/testdata/dir
    -In same hierarchy, somewhere else:
        /tmp/testdata/dir/dir2/otherblah -> /tmp/testdata/dir/file

  The last two cases are very similar, the only difference
  will be that it will create '../' for the first rather
  than the possible '../../dir'.  The last case will indeed
  get the '../file'.

=cut

sub convert_to_relative{
  my($link_loc, $realfile) = (shift, shift);
  my $i;
  my $result;
  my($new_realfile, $new_link, @realfile_parts, @link_parts);

  @realfile_parts = split m#/#, $realfile;
  @link_parts = split m#/#, $link_loc;

  for ( $i = 0; $i < @realfile_parts; $i++ ) {
    last unless $realfile_parts[$i] eq $link_parts[$i];
  }

  $new_realfile = join '/', @realfile_parts[$i..$#realfile_parts];
  $new_link = join '/', @link_parts[$i..$#link_parts];

  if( $i == 1 ){
    $result = $realfile;
  } elsif ( $i > $#realfile_parts and $i == $#link_parts  ) {
    $result = '.';
  } elsif ( $i == $#realfile_parts and $i == $#link_parts ) {
    $result = $realfile_parts[$i];
  } elsif ( $i >= $#link_parts  ) {
    $result = join '/', @realfile_parts[$i..$#realfile_parts];
  } else {
    $result = '../' x ($#link_parts - $i);
    $result .= join '/', @realfile_parts[$i..$#realfile_parts]
      if $#link_parts - $i > 0;
  }

  return $result;

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
  #throw away the first line, it should be a "total" line
  shift unless $options{KeepFirstLine};

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
					    IsSymlink => 0,
					    IsDirectory => 0,
					    OriginalLine => $line,
					    Fields => [@fields]);
    } elsif ($perms =~ /^d/) {
      $file = new Net::FTP::Recursive::File(IsDirectory => 1,
					    IsSymlink => 0,
					    IsPlainFile => 0,
					    OriginalLine => $line,
					    Fields => [@fields]);
    } elsif ($perms =~/^l/) {
      $file = new Net::FTP::Recursive::File(IsSymlink => 1,
					    IsDirectory => 0,
					    IsPlainFile => 0,
					    OriginalLine => $line,
					    Fields => [@fields]);
    }

    push(@to_return, $file);

  }

  #doing a little extra work to make sure we always look at
  #the directories first...though I don't think it matters
  #anyway (the rationale behind this is that we want a
  #consistent ordering to the retrieval/listing of the
  #files, particularly when FlattenTree is in effect
  return( map{$_->[0]} 
	  sort {$a->[1] <=> $b->[1]}
	  map {[$_, $_->isDirectory()]} @to_return);

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

sub linkname{
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

NOTE: This module will most definitely not work under Windows, nor is
it likely to be ported to Windows.

C<Net::FTP::Recursive> is a class built on top of the
Net::FTP package that implements recursive get and put
methods for the retrieval and sending of entire directory
structures.

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

When the C<Debug> flag is used with the C<Net::FTP> object,
the C<Recursive> package will print some messages to
C<STDERR> (Along with the output that the C<Net::FTP> module
prints to C<STDERR>).

Most of the module's methods have an optional C<SymlinkFollow>
flag that may be passed to them, this flag will try to
traverse symlinks and recurse into them if they link to a
directory.  Along with this, there is cycle detection.  The
behavior of the cycle detection is as follows:

The link is first checked to see if it's part of the tree
that will be recursively operated upon (by knowing where the
method started its operation).

If it is, a symlink is made to that other location.

If it's not going to be operated upon automatically, a hash
is checked first to see if it has already been seen
somewhere else.

If it has been seen, a symlink is made to it with the
information that is in the hash.

In either case, if the symlink is made, it is made to be a
relative link to allow for the structure to be moved without
breaking the links.

Otherwise, a directory with the same name as the link on the
remote filesystem is made, and the operation recurses into
the directory.

All of the methods also take an optional C<KeepFirstLine>
argument which is passed on to the default parsing routine.
This argument supresses the discarding of the first line of
output from the dir/ls command.  Some ftp servers provide a
total line, the default behavior is to throw that total line
away.  If yours does not provide the total line,
C<KeepFirstLine> is for you.  This argument is used like the
others, you provide the argument as the key in a key value
pair where the value is true (ie, KeepFirstLine => 1).

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


=item rget ( [ParseSub =>\&yoursub] [FlattenTree => 1] [RemoveRemoteFiles => 1] )

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

=item SymLinkFollow - will recurse into a symlink if it
points to a directory.  This does not do cycle checking, use
with caution.  This option may be given along with one of
the others above.

=back

The C<FlattenTree> optional argument will retrieve all of
the files from the remote directory structure and place them
in the current local directory.  This option will resolve
filename conflicts by retrieving files with the same name
and renaming them in a "$filename.$i" fashion, where $i is
the number of times it has retrieved a file with that name.

The optional C<RemoveRemoteFiles> argument to the function
will allow the client to delete files from the server after
it retrieves them.  The default behavior is to leave all
files and directories intact.

=item rput ( [ParseSub => \&yoursub] [DirCommand => $cmd] [FlattenTree => 1] [RemoveLocalFiles => 1])

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

=item SymlinkFollow - will recurse into a symlink if it
points to a directory.  This does not do cycle checking, use
with caution.  This option may be given with one of the
options above.

=back

The C<FlattenTree> optional argument will send all of the
files from the local directory structure and place them in
the current remote directory.  This option will resolve
filename conflicts by sending files with the same name
and renaming them in a "$filename.$i" fashion, where $i is
the number of times it has retrieved a file with that name.

The optional C<RemoveLocalFiles> argument to the function
will allow the client to delete files from the client after
it sends them.  The default behavior is to leave all
files and directories intact.

=item rdir ( Filehandle => $fh [, FilenameOnly => 1 ] [, ParseSub => \&yoursub ] [SymlinkFollow => 1] )

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
breadth-first fashion.  This is equivalent to calling
C<$ftp->rdir( Filehandle => $fh, FilenameOnly => 1 )>.

=item rdelete ( [ ParseSub => \&yoursub ] )

The recursive delete method call.  This will recursively
delete everything in the directory structure.  This
disregards the C<SymlinkFollow> option and does not recurse
into symlinks that refer to directories.

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

And it should also be passed at least one (but only one with
a true value) of:

=over

=item IsPlainFile

=item IsDirectory

=item IsSymlink

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

(in Chronological order)

Andrew Winkler - for various input into the module.
Raj Mudaliar - documentation fix.
Brian Reischl - for rdelete code.
Chris Smith - for RemoveRemoteFiles code.
Zainul Charbiwala - bug report & code to fix.

=head1 COPYRIGHT

Copyright (c) 2001-2003 Jeremiah Lee.

This program is free software; you may redistribute it
and/or modify it under the same terms as Perl itself.  It
comes with NO WARRANTY and NO GUARANTEE whatsoever.
If you use this to really screw up your system, you're on
your own.

=cut

