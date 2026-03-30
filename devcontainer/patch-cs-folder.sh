#!/bin/bash
# Patch the code-server entrypoint to open /workspace instead of /home/node.
# Called via postCreateCommand so it runs once after every container (re)build.
if [ -f /usr/local/bin/code-server-entrypoint ]; then
  sed -i 's|"/home/node"|"/workspace"|g' /usr/local/bin/code-server-entrypoint
fi
