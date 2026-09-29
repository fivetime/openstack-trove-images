# Runs inside a backup image: checks that the image can load the driver
# for one backup strategy. Usage: python3 - <strategy> < smoke.py, with the
# image's working directory (the backup sources) as the current directory.
#
# "main.py --help" is no use for this: it exits before the driver name is
# checked, so it succeeds for a driver that does not exist.

import os
import sys

from oslo_utils import importutils

sys.path.insert(0, os.getcwd())
import main  # noqa: E402

# Same order as main(): register and parse first, because the drivers read
# the configuration when their classes are defined. Parsing also checks the
# driver against the allowed choices.
main.CONF.register_cli_opts(main.cli_opts)
main.CONF(['--driver', sys.argv[1]], project='trove-backup')
names = [main.CONF.driver]
# Incremental backups use the driver registered under "<name>_inc".
if names[0] + '_inc' in main.driver_mapping:
    names.append(names[0] + '_inc')
for name in names:
    cls = importutils.import_class(main.driver_mapping[name])
    print('driver', name, '=', cls.__module__ + '.' + cls.__name__)
