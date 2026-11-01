#!/usr/bin/env sh
# Write .env next to compose.yml, with a random database password and bootstrap key.
# Leaves an existing .env alone, so running it twice cannot lock you out of your database.
set -eu
umask 077 # .env holds secrets: create it readable by its owner only

cd "$(dirname "$0")"
if [ -f .env ]; then
  echo ".env already exists; leaving it as it is."
  exit 0
fi

random() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
password=$(random 24)
bootstrap="dk_boot_$(random 24)"

sed -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$password|" \
    -e "s|^DITEKO_AUTH_BOOTSTRAPKEY=.*|DITEKO_AUTH_BOOTSTRAPKEY=$bootstrap|" \
    .env.example > .env
chmod 600 .env

echo "Wrote .env. Your bootstrap key (an admin key; you need it once, in step 4 of README.md):"
echo
echo "  $bootstrap"
echo
echo "Next: docker compose up -d"
