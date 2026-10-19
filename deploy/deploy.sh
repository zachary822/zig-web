#!/usr/bin/env bash
# Deploys zig-web on the Pi: pulls the latest commit, builds the server and
# the CSS, copies the static files for nginx, applies the migrations, and
# restarts the server.
#
# Run it in the clone (/home/pi/zig-web) as the user pi:
#
#     ./deploy/deploy.sh            # pull and deploy
#     ./deploy/deploy.sh --no-pull  # deploy the commit that is checked out
#
# It asks for the sudo password one time, for `systemctl restart`.
#
# The script does not install deploy/zig-web.service or the nginx files. If
# they differ from the installed copies, it shows a warning; install them by
# hand (see the comments in those files).

set -euo pipefail

pull=true
for arg in "$@"; do
    case "$arg" in
        --no-pull) pull=false ;;
        -h | --help)
            sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "deploy.sh: unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

# The flags for each `zig build`. The same flags let the later steps use
# the cache of the first build. -Ddb=true makes the build stop if
# libmariadb is missing, instead of a server without a database.
zig_flags=(-Doptimize=ReleaseSafe -Ddb=true)

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
    printf '\033[31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

cd "$(dirname "$0")/.."

# Only one deploy at a time.
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/zig-web-deploy.lock"
flock -n 9 || die "a different deploy is in progress"

step "Examine the requirements"
[[ -f .env ]] || die ".env is missing (see .env.example)"
# The default MEDIA_DIR (media/ in the clone) is not writable under systemd
# (ProtectHome=read-only), so the server would not start.
media_dir=$(sed -n 's/^MEDIA_DIR=//p' .env | tail -n 1 | tr -d "\"'")
[[ -n $media_dir ]] || die "MEDIA_DIR is not set in .env (see deploy/zig-web.service)"
[[ -d $media_dir && -w $media_dir ]] || die "MEDIA_DIR=$media_dir is not a writable directory (see deploy/zig-web.service)"
for cmd in zig pkg-config curl flock; do
    command -v "$cmd" >/dev/null || die "$cmd is not in PATH"
done
zig_version=$(zig version)
[[ $zig_version == 0.17.* ]] || die "zig $zig_version found, 0.17 is necessary"
pkg-config --exists libmariadb || die "pkg-config does not find libmariadb (apt install libmariadb-dev)"
# Node and npm come from nvm, which a non-interactive shell does not load.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if ! command -v npm >/dev/null && [[ -s $NVM_DIR/nvm.sh ]]; then
    # nvm.sh does not work with `set -eu`.
    set +eu
    # shellcheck source=/dev/null
    . "$NVM_DIR/nvm.sh"
    set -eu
fi
command -v npm >/dev/null || die "npm is not in PATH, and nvm did not give it"
echo "zig $zig_version, node $(node --version)"

before=$(git rev-parse HEAD)
if $pull; then
    step "Pull"
    [[ $(git branch --show-current) == main ]] || die "the clone is not on main"
    git diff --quiet && git diff --cached --quiet || die "the clone has changes that are not committed"
    git pull --ff-only
fi
after=$(git rev-parse HEAD)
if [[ $before == "$after" ]]; then
    echo "At $(git log -1 --format='%h %s')"
else
    git log --oneline "$before..$after"
fi

step "Install the npm packages"
if [[ ! -d node_modules ]] || ! git diff --quiet "$before" "$after" -- package.json package-lock.json; then
    npm ci
else
    echo "package-lock.json did not change: skipped"
fi

step "Build the CSS"
zig build css

step "Build the server"
zig build "${zig_flags[@]}"

# Before the restart: the new server refers to the hashed names of the new
# static files.
step "Copy the static files"
zig build collectstatic "${zig_flags[@]}"

step "Apply the migrations"
./zig-out/bin/zig_web_migrate

step "Restart the server"
sudo systemctl restart zig-web

# The server can need some seconds to hash the static files and connect to
# the database.
port=$(sed -n 's/^PORT=//p' .env | tail -n 1 | tr -d "\"'")
port=${port:-8080}
status=000
for _ in $(seq 20); do
    sleep 0.5
    status=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/" || true)
    [[ $status == 2* || $status == 3* ]] && break
done
if ! systemctl is-active --quiet zig-web || [[ $status != 2* && $status != 3* ]]; then
    journalctl -u zig-web -n 40 --no-pager >&2 || true
    die "the server does not reply on port $port (HTTP $status), see the log above"
fi
echo "The server replies on port $port (HTTP $status)"

step "Examine the installed configuration"
check_installed() {
    local repo_file=$1 installed=$2
    if [[ ! -f $installed ]]; then
        warn "$installed is missing (see $repo_file)"
    elif ! cmp -s "$repo_file" "$installed"; then
        warn "$installed differs from $repo_file: install it by hand if the change is intended"
    fi
}
check_installed deploy/zig-web.service /etc/systemd/system/zig-web.service
check_installed deploy/nginx/site.conf /etc/nginx/sites-available/zig-web
check_installed deploy/nginx/zig_web.conf /etc/nginx/snippets/zig_web.conf
check_installed deploy/nginx/zig_web_compress.conf /etc/nginx/snippets/zig_web_compress.conf

step "Deployed $(git log -1 --format='%h %s')"
