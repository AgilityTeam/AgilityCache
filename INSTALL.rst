To test, run::

        make
        make generate
        chmod +x ./rel/mynode/bin/mynode
        ./rel/mynode/bin/mynode start

The default configuration file resides in
``apps/agilitycache/src/agilitycache.app.src``. It saves cached files
in ``/opt/agilitycache/var/cache``, and the database resides in
``/opt/agilitycache/var/database``. Be sure to check the permissions
of these path.



