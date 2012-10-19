#!/usr/bin/env python

"""usage:    %s  [source-dir [dest-dir]]

source-dir defaults to the current dir, and dest-dir defaults to home.

Symlinks everything in source to dest
"""

__doc__ = __doc__ % __file__

import os
import sys

def main(link_target_dir, dest):
    link_target_dir = os.path.abspath(link_target_dir)
    dest   = os.path.abspath(dest)
    if dest == link_target_dir:
        # don't want to unlink every damned thing
        print __doc__
        return

    for fname in os.listdir(link_target_dir):

        linkfile = os.path.join(dest, '.' + fname)
        source_file = os.path.join(link_target_dir, fname)

        if os.path.islink(linkfile) or fname.startswith('.'):
            continue
        elif os.path.exists(linkfile):
            agrees = raw_input('replace %s with a link to %s [y/N]: ' %
                               (linkfile, source_file))
            if not agrees.strip() == 'y':
                continue
            os.unlink(linkfile)

        print 'symlinking %s to %s' % (linkfile, source_file)
        os.symlink(source_file, linkfile)

if __name__ == '__main__':
    default_src = os.path.join(os.getenv('HOME'), 'configs')

    if len(sys.argv) == 2:
        if sys.argv[1] == '-h' or sys.argv[1] == '--help':
            print __doc__
            exit(1)

    if len(sys.argv) == 1:
        main(default_src, os.getenv('HOME'))

    elif len(sys.argv) == 2:
        main(sys.argv[1], os.getenv('HOME'))

    elif len(sys.argv) == 3:
        main(sys.argv[1], sys.argv[2])

    else:
        print __doc__
        exit(1)
