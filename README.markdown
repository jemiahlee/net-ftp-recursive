# Net/FTP/Recursive

This module augments the list of Net::FTP methods with several
methods that automatically descend directory structures for you.
The methods are:

     rget - Retrieve an entire directory tree.
     rput - Send an entire directory tree.
     rdir - Receive an entire directory tree listing.
     rls  - Receive an entire directory tree listing, filenames
            only.
     rdelete - Remove an entire directory tree.

There are several sample scripts that illustrate some of the
possible usages of these methods.  Please see the "samples"
directory in this distribution or check the documentation that
comes with the module.

## INSTALLATION

To install this module type the following:

```
   perl Makefile.PL
   make
   make install
```

### DEPENDENCIES

This module requires these other modules and libraries:

Net::FTP is required.  This module builds its functionality
on top of this module.  You should be able to get the Net::FTP
module from http://cpan.org/modules/by-module/Net.

### COPYRIGHT AND LICENCE

Copyright (C) Jeremiah Lee <texasjdl_AT_yahoo.com>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.  Use it at your own risk,
there is NO GUARANTEE or WARRANTY, implied or otherwise.
