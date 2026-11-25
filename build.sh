#!/usr/bin/env bash
# Render build bosqichi.
#
# Haqiqiy kod PRIVATE repo'da (abdulroufjon726-create/barberflow-app). Render
# private repo'ni o'zi clone qila olmaydi, shuning uchun bu ochiq "shim" repo
# faqat deploy key bilan clone qilib, oddiy Django build'ini bajaradi.
# Kalit Render'ning DEPLOY_KEY_B64 env var'ida turadi, repo'da hech qanday
# sir yo'q.
set -o errexit

: "${DEPLOY_KEY_B64:?DEPLOY_KEY_B64 env var kerak (Render -> Environment)}"

mkdir -p "$HOME/.ssh"
printf '%s' "$DEPLOY_KEY_B64" | base64 -d > "$HOME/.ssh/barberflow_deploy"
chmod 600 "$HOME/.ssh/barberflow_deploy"
ssh-keyscan -H github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/barberflow_deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes"

rm -rf app
git clone --depth 1 git@github.com:abdulroufjon726-create/barberflow-app.git app

cd app/backend
pip install --upgrade pip
pip install -r requirements.txt

python manage.py collectstatic --noinput
python manage.py migrate --noinput

if [ "${SEED_DEMO:-1}" = "1" ]; then
  python manage.py seed_demo
fi
