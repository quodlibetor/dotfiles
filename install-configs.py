#!/usr/bin/env python

"""usage:    %s [-y] [source-dir [dest-dir]]

source-dir defaults to the current dir, and dest-dir defaults to home.

Symlinks everything in source to dest. Asks before overwriting, unless -y
is supplied.
"""

__doc__ = __doc__ % __file__

import os
import sys

def main(link_target_dir, dest, yes):
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
            if yes:
                agrees = yes
            else:
                agrees = raw_input('replace %s with a link to %s [y/N]: ' %
                                   (linkfile, source_file))
                if not agrees.strip() == 'y':
                    continue
            os.unlink(linkfile)

        print 'symlinking %s to %s' % (linkfile, source_file)
        os.symlink(source_file, linkfile)

if __name__ == '__main__':
    source_dir = os.path.join(os.getenv('HOME'), 'configs')
    target_dir = os.getenv('HOME')

    if '-y' in sys.argv:
        yes = True
    else:
        yes = False
    sys.argv = [a for a in sys.argv if a != '-y']
    if len(sys.argv) == 2:
        if sys.argv[1] == '-h' or sys.argv[1] == '--help':
            print __doc__
            exit(1)

    elif len(sys.argv) >= 2:
        source_dir = sys.argv[1]

    elif len(sys.argv) == 3:
        target_dir = sys.argv[2]
    elif len(sys.argv) > 3:
        print __doc__
        exit(1)

    main(source_dir, target_dir, yes)
