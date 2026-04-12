#!/bin/sh
set -eu

if [ ! -s /run/symphony/ssh/authorized_key.pub ]; then
  echo "missing authorized key at /run/symphony/ssh/authorized_key.pub" >&2
  exit 1
fi

install -d -m 700 -o worker -g worker /home/worker/.ssh
install -m 600 -o worker -g worker /run/symphony/ssh/authorized_key.pub /home/worker/.ssh/authorized_keys

# claude-config volume mount lands at /home/worker/.claude with host ownership.
# Make sure the worker user can read/write it.
if [ -d /home/worker/.claude ]; then
  chown -R worker:worker /home/worker/.claude
fi

exec /usr/sbin/sshd -D -e
