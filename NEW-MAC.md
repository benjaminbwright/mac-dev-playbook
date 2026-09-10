# Setting up a new Mac with this playbook

Step-by-step for provisioning a brand-new MacBook from this repo. Commands match
[README.md](README.md); package/app definitions live in [default.config.yml](default.config.yml).

## Order of operations

### 1. Finish Apple's setup wizard
Create your local user account, sign into iCloud, get to the desktop.

### 2. Sign into the Mac App Store
Open **App Store → sign in**. Mandatory — `mas` can't sign in for you, and the
playbook installs App Store apps (Xcode, Logic Pro, Todoist, Sketch, etc.). They
fail silently if you're not signed in.

### 3. Install Apple's command line tools
```bash
xcode-select --install
```
Wait for it to finish before continuing.

### 4. Install Homebrew
The `geerlingguy.mac.homebrew` role *can* bootstrap Homebrew itself, but its
git-clone method is fragile and fails with *"source file does not exist
(/opt/homebrew/Homebrew/bin/brew)"* when it doesn't produce a working `brew`.
Install Homebrew the official way first; the role then detects it and skips the
brittle bootstrap.
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Put brew on PATH (Apple Silicon):
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"

brew --version   # confirm
```

### 5. Install Ansible
Use Homebrew (installed in step 4) — its `ansible*` commands land in
`/opt/homebrew/bin`, which is already on PATH, so there's nothing extra to fix:

```bash
brew install ansible
ansible --version   # confirm
```

The playbook then keeps Ansible installed (it's in `homebrew_installed_packages`),
so it stays available at `/opt/homebrew/bin` for `make`, cron, and bare shells.

> Prefer pip? `pip3 install --upgrade pip && pip3 install ansible` also works, but
> it drops the commands in your Python **user bin** (`~/Library/Python/3.x/bin`),
> which isn't on PATH by default — you'd then need:
> `echo 'export PATH="$(python3 -m site --user-base)/bin:/opt/homebrew/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc`.
> The Homebrew route avoids all of that.

### 6. Clone this repo
```bash
git clone git@github.com:benjaminbwright/mac-dev-playbook.git
cd mac-dev-playbook
```
No SSH keys on the new machine yet? Use HTTPS:
`git clone https://github.com/benjaminbwright/mac-dev-playbook.git`

> **Set up GitHub SSH access now** if you haven't. The dotfiles step clones a
> **private** repo (`benjaminbwright/dotfiles`) over SSH, so it fails without it.
> Quickest path: `gh auth login` (then `gh auth setup-git`), or add an SSH key to
> GitHub. Verify with `ssh -T git@github.com`.

### 7. Install required roles/collections
```bash
ansible-galaxy install -r requirements.yml
```

### 8. Sanity-check first (recommended)
```bash
ansible-playbook main.yml --syntax-check
ansible-playbook main.yml --check --ask-become-pass --tags homebrew,mas
```
`--check` is a dry run — shows what would change without touching anything.

### 9. Run it
```bash
ansible-playbook main.yml --ask-become-pass
```
Enter your macOS password at the **BECOME** prompt. With Homebrew already installed
(step 4), the role skips its bootstrap and goes straight to installing packages.
Run subsets with tags, e.g.:
```bash
ansible-playbook main.yml -K --tags "homebrew,mas"
```

## After the playbook — manual installs

The playbook can't install these. Full list lives in the **MANUAL INSTALLS** block
in [default.config.yml](default.config.yml):

- **Adobe Creative Cloud** — [CC desktop app](https://creativecloud.adobe.com/apps/download/creative-cloud), then Photoshop / Illustrator / Premiere / etc.
- **Codex** — https://persistent.oaistatic.com/sidekick/public/ChatGPT.dmg
- **Join** — https://joaoapps.com/join/
- **BookWright** — https://www.blurb.com/bookwright
- **GoodMorning** / **Victory Shield** — source TBD; copy the `.app` from the old Mac's
  `/Applications` in the meantime.

### Restoring local databases

Local MySQL / PostgreSQL / MongoDB data and Docker named volumes don't come across
with the playbook — carry them over with the two scripts in [scripts/](scripts/).
Both skip anything that isn't installed or running, so it's safe to run them on
either machine as-is.

**On the old Mac** (with the DB services + Docker running):

```bash
MYSQL_PWD=root scripts/db-dump.sh --volumes my_pg_data,my_redis_data   # or omit --volumes
```

Writes `~/Development/db-dumps/<YYYY-MM-DD>/` (mysqldump `--all-databases`,
`pg_dumpall`, `mongodump`, one `.tar.gz` per volume) and points
`~/Development/db-dumps/latest` at it. Add `--dry-run` to see the plan first,
`--dir DIR` to write elsewhere.

**Copy** `~/Development/db-dumps` to the new Mac (it lives outside any git repo —
use Migration Assistant, AirDrop, rsync, whatever).

**On the new Mac**, after the playbook has installed and started the services:

```bash
ansible-playbook main.yml -K --tags db-restore
```

That calls `scripts/db-restore.sh --dir ~/Development/db-dumps/latest --yes` (plus
`--volumes` from `db_docker_volumes`) and is a no-op if the dump dir isn't there.
The tag is opt-in (`never`), so a normal playbook run never restores anything.
Override `db_dump_dir` / `db_docker_volumes` in `config.yml` as needed, or run the
script by hand — without `--yes` it only prints the plan:

```bash
scripts/db-restore.sh --dir ~/Development/db-dumps/2026-09-10          # plan only
scripts/db-restore.sh --dir ~/Development/db-dumps/2026-09-10 --yes    # do it
```

## Troubleshooting

**"Gathering Facts" fails with `/opt/homebrew/bin/python3: no such file or directory`**
This happens when `ansible_python_interpreter` is pinned to a Homebrew Python that
doesn't exist yet (Homebrew is installed *during* the playbook, but facts are
gathered first). `default.config.yml` now uses `ansible_python_interpreter: auto_silent`
so Ansible discovers an existing Python — pull the latest of this repo if you still
see the hardcoded path. As a one-off override you can also pass:
`ansible-playbook main.yml --ask-become-pass -e ansible_python_interpreter=auto_silent`

**`Symlink brew ...` fails: "source file does not exist (/opt/homebrew/Homebrew/bin/brew)"**
Homebrew isn't actually installed — the role's git-clone bootstrap didn't produce a
working `brew`. Recover by installing Homebrew officially, then re-running:
```bash
sudo rm -rf /opt/homebrew                                   # clear the partial bootstrap
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"
brew --version
ansible-playbook main.yml --ask-become-pass                 # role now skips the bootstrap
```
This is exactly why step 4 installs Homebrew up front.

**App Store apps fail ("Required `mas` tool is not installed", or apps don't install)**
Two quirks of modern `mas` (7.x): it **requires root** to install apps, and under
`sudo` the Homebrew bin dir leaves PATH so `mas` can't be found by name. The
`geerlingguy.mac.mas` 5.0.0 role hits the second issue and fails. This repo
**disables that role** and installs App Store apps in [tasks/mas.yml](tasks/mas.yml)
using `become: true` plus an **absolute path** to `mas`. Pull the latest if you
still see the role running.

`mas` can only install apps **already associated with your Apple ID**. Paid apps
you don't own can't be installed by any tool — buy them once in the App Store.
`tasks/mas.yml` does not fail the play on an app it can't install — it prints which
ones need attention. (Note: `mas account`/`mas signin` were removed in mas 2.0+, so
sign-in is detected from the App Store app; just make sure you're signed in there.)

**Homebrew installs fail in bulk with "The following taps are not trusted"**
Newer Homebrew won't load formulae from third-party taps unless trusted, and exits
non-zero on every `brew install` while any untrusted tap is present — so the Ansible
homebrew module marks almost everything failed (and `mongodb-community` hard-fails).
`main.yml` sets `HOMEBREW_NO_REQUIRE_TAP_TRUST=1` for the play to disable this gate
for the taps we declare. Pull the latest if you still see trust warnings. (If a
future Homebrew removes that flag, run `brew trust hashicorp/tap bufbuild/buf
mongodb/brew github/gh` once instead.)

**Homebrew formulae all report "failed: … already installed and up-to-date" on a re-run**
The `community.general.homebrew` module's idempotency check is unreliable against
current Homebrew: it doesn't recognize already-installed packages, runs `brew
install` anyway, then treats brew's "already installed" notice as a failure.
`main.yml` therefore skips the role's formula loop (`homebrew_installed_packages: []`
on the role) and installs formulae in its own tolerant task that treats "already
installed" as unchanged. The role still handles taps and casks. Nothing was being
reinstalled or damaged — the packages were fine; only the status reporting was wrong.

## Dotfiles & shell config

The playbook clones your private [dotfiles repo](https://github.com/benjaminbwright/dotfiles)
to `~/Development/GitHub/dotfiles` and symlinks the tracked files into `~`
(`.zshrc`, `.aliases`, `.gitconfig`, `.gitignore`, `.inputrc`, `.vimrc`, `.osx`,
`.zshenv`). Run just that part with `--tags dotfiles`.

**Secrets are not in the repo.** Machine-local / sensitive shell config lives in
`~/.zshrc.local` (gitignored, sourced at the end of `.zshrc`). On a new Mac it
won't exist yet, so after the dotfiles step:

```bash
# Option A — copy from your old Mac (both alive during migration):
scp old-mac:~/.zshrc.local ~/.zshrc.local

# Option B — start from the template and fill in values:
cp ~/Development/GitHub/dotfiles/.zshrc.local.example ~/.zshrc.local
$EDITOR ~/.zshrc.local
```

To change dotfiles later: edit the file in `~` (it's a symlink into the repo),
then `dotfiles commit -am "..."` and `dotfiles push`; on another machine
`dotfiles-pull`. Commit before re-running `--tags dotfiles` (the symlinked files
always show as local edits in the repo).

## Document sync (Syncthing)

The playbook installs the `syncthing` formula and starts it as a login service
(`brew services`), so the daemon runs continuously in the background. The playbook
**can't** pair it to your server (device IDs/folders are interactive) — do that once
in the web UI:

```bash
open http://localhost:8384
```
Add your local Syncthing server's **Device ID**, accept the pairing on the server,
then share/accept the folders you want synced into `~`. Run just this step with
`--tags syncthing`.

## Cloning your repos

The playbook can clone your git repos onto the new Mac. The repo list
(`git_repositories`) lives in the **private dotfiles repo** as `repos.yml`
(it leaks repo/project names, so it is not in this public playbook). `main.yml`
loads `~/Development/GitHub/dotfiles/repos.yml` automatically when it exists, so
the list arrives with the dotfiles clone — nothing to hand-copy. A
`git_repositories` list in the gitignored `config.yml` still works as a fallback;
`repos.yml` wins when both define it.

Run with `--tags repos` (needs GitHub SSH access). On a fresh Mac the dotfiles
repo is cloned by the main run, so run this *after* the full playbook:

```bash
ansible-playbook main.yml --ask-become-pass --tags repos
```

It clones each repo's default branch if missing and never disturbs an existing
checkout (`update: false`). **Cloning only pulls what's on the remote** — commit
and push everything on the old Mac first; uncommitted changes, unpushed commits,
local-only branches, and no-remote repos do NOT transfer (hand-copy those).

**Capture / re-capture the list** on the old Mac with the generator script. It
scans `~/praxis-loop`, `~/Development/GitHub`, `~/active-git`, `~/sandbox`,
`~/xpow` and `~/agent-avocado` by default (pass folders to override), finds git
repos up to two levels deep, skips `wt-*` worktree checkouts and repos with no
remote (listed on stderr), and prints the YAML grouped by folder. Preview to the
terminal first, then write it into the dotfiles clone and commit there:

```bash
scripts/generate-repo-manifest.sh                       # preview on stdout
scripts/generate-repo-manifest.sh -o ~/Development/GitHub/dotfiles/repos.yml
$EDITOR ~/Development/GitHub/dotfiles/repos.yml         # prune what you don't want
git -C ~/Development/GitHub/dotfiles add repos.yml \
  && git -C ~/Development/GitHub/dotfiles commit -m "Update repo manifest" \
  && git -C ~/Development/GitHub/dotfiles push
```

### Repo secrets (.env files)
The gitignored `.env`/config files aren't in the repos. They live vault-encrypted
in a separate private repo, [benjaminbwright/secrets](https://github.com/benjaminbwright/secrets),
which the playbook **clones for you** (the `--tags repos` step, to
`~/Development/GitHub/secrets`). Once your repos are cloned, restore the secrets:

```bash
cd ~/Development/GitHub/secrets
# optional: skip the prompt -> printf '%s' 'PASSWORD' > .vault_pass && chmod 600 .vault_pass
make restore
```

Needs your ansible-vault password. `make help` lists the other commands
(`update`, `rekey`, …); see that repo's README.

### Claude Code global config
Your global Claude config (`settings.json`, `settings.local.json`, `config.json`,
and your skills) is snapshotted in the private dotfiles repo under `claude/`. The
playbook **seeds** it into `~/.claude` (the `--tags claude` step) on a fresh Mac —
it won't overwrite a machine that already has settings/skills. Re-capture with:

```bash
DF=~/Development/GitHub/dotfiles
cp ~/.claude/{settings.json,settings.local.json,config.json} "$DF/claude/"
rsync -aL --delete --exclude .DS_Store ~/.claude/skills/ "$DF/claude/skills/"
git -C "$DF" add claude && git -C "$DF" commit -m "Update Claude config" && git -C "$DF" push
```

## Re-capturing editor config

VS Code and Cursor settings, keybindings, and extension lists are restored by the
playbook from `files/vscode/` and `files/cursor/` (`--tags editors`). Whenever you
tweak a setting or add/remove an extension on your live Mac, re-capture so the repo
keeps matching the machine:

```bash
scripts/capture-editors.sh --check   # exit 1 and list drifted files; writes nothing
scripts/capture-editors.sh           # copy live config into files/{vscode,cursor}/
git add files && git commit -m "Re-capture editor config" && git push
```

The script uses the `code` / `cursor` shell commands (installed by the Homebrew
casks, or via the Command Palette → "Shell Command: Install ... in PATH"); an
editor whose command isn't found is skipped. Tests: `bats tests/`.

## Services and login items

`tasks/services.yml` (run alone with `--tags services`) reproduces the background
bits of the old Mac. Everything is driven from `default.config.yml`:

- **Homebrew services** — `homebrew_services_started` lists what gets
  `brew services start`ed as a login service: `mysql`, `mongodb-community`,
  `syncthing` (what the old Mac actually ran). `postgresql@14` and `caddy` are
  installed but deliberately *not* started; add them to the list to opt in.
- **MySQL root password** — the `root`/`root` setup in `main.yml` now waits for
  `mysqladmin ping` on `/tmp/mysql.sock` (up to ~30s) and is skipped if the server
  never answers, and always skipped under `--check`. If it was skipped, run
  `mysqladmin --socket=/tmp/mysql.sock ping` to see why MySQL isn't up
  (`brew services info mysql`, then `--tags services` again).
- **active-git LaunchAgent** — off by default (`configure_active_git_agent: false`).
  The old Mac's `~/Library/LaunchAgents/com.active-git.plist` pointed at a Cellar
  path for node 19.2.0 that no longer exists, so it was already dead. Set the flag
  to `true` to template it from `templates/com.active-git.plist.j2` (stable
  `/opt/homebrew/bin/node`, hourly at :05) and load it; needs the `active-git`
  npm package on PATH. Remove the old plist by hand on the old Mac if you want:
  `launchctl bootout gui/$(id -u)/com.active-git; rm ~/Library/LaunchAgents/com.active-git.plist`.
- **Login items** — `login_items` (Dropbox, Google Drive, Claude) are added via
  System Events only if missing; apps not yet installed are skipped, so re-run
  `--tags services` after the manual installs above. macOS asks once to let
  Terminal control System Events - click OK. The remaining old-Mac login items,
  **FigmaAgent** and **Acrobat Collaboration Synchronizer**, are helpers that
  Figma and Acrobat register themselves the first time they run (they live inside
  the apps, not in `/Applications`), so they are not managed here.

## Installer-based CLIs

Four CLIs on the old Mac came from vendor `curl | sh` installers rather than
Homebrew ([issue #10](https://github.com/benjaminbwright/mac-dev-playbook/issues/10)).
The playbook now covers all of them — three moved to Homebrew (installed with
`--tags homebrew`), one keeps its vendor installer (`--tags installer-clis`):

| Tool | Old Mac | Playbook |
|---|---|---|
| `codex` | `~/.local/bin` (vendor installer) | Homebrew cask `codex` |
| `cursor-agent` | `~/.local/bin` (vendor installer) | Homebrew cask `cursor-cli` (ships the `cursor-agent` binary) |
| `limbo` | `~/.limbo` (vendor installer) | Homebrew formula `turso` — same project, renamed upstream; the binary is now `tursodb` and `~/.limbo` is not created |
| `pocket-server` | `~/.pocket-server/bin` | Vendor installer, run by [tasks/installer-clis.yml](tasks/installer-clis.yml); skipped once `~/.pocket-server/bin/pocket-server` exists |

```bash
ansible-playbook main.yml --ask-become-pass --tags installer-clis
```

### Make the shell safe when a tool is missing
The tracked `.zshrc` puts `~/.pocket-server/bin` on PATH, sources `~/.limbo/env`
and defines two `pocket-server` aliases. On a fresh Mac none of that exists until
the steps above have run, so [scripts/guard-shell-rc.sh](scripts/guard-shell-rc.sh)
rewrites an rc file so each such line is guarded: `[ -d … ] &&` for PATH dirs
(a dir mixed into a longer PATH line is split out into its own guarded line, so
the other dirs stay on PATH), `[ -f … ] &&` for sourced files, and
`command -v … &&` for the aliases. It only touches lines it recognises, running
it twice changes nothing, and it keeps a one-time `<file>.bak` of the original.

Run it **from this repo's directory** against the dotfiles clone (not the
symlink in `~`), review, then commit in the dotfiles repo:

```bash
scripts/guard-shell-rc.sh ~/Development/GitHub/dotfiles/.zshrc
git -C ~/Development/GitHub/dotfiles diff .zshrc      # review the guards
rm ~/Development/GitHub/dotfiles/.zshrc.bak            # backup no longer needed
git -C ~/Development/GitHub/dotfiles commit -am "Guard installer-based CLI lines in .zshrc"
git -C ~/Development/GitHub/dotfiles push
```

The same command works for any other rc file you later track (e.g. `.zprofile`,
which currently adds `~/.local/bin` to PATH — see issue #8).

## Good to know

- [main.yml](main.yml) starts MySQL/MongoDB services, sets a root MySQL password
  (`root`/`root`), and runs `rustup-init`. Expected behavior.
- Override anything in `default.config.yml` by creating a `config.yml` (gitignored,
  globbed by `main.yml` pre_tasks) — see [README.md](README.md).

## Decommissioning the old Mac

Before wiping it:
- Sign out of Adobe Creative Cloud
- Sign out of Panic Sync in Transmit
- Sign out of Steam
- Deauthorize Apple Music
- Unlink / deauthorize Dropbox (Preferences > Account > Unlink This Dropbox)
- Disconnect Google Drive (Google Drive menu > Settings > Disconnect account)
- Remove the old Mac from Tailscale (admin console > Machines) and from Syncthing on the server side (remove the old device ID from the server's device list)
- Revoke the old Mac's SSH key on GitHub and on the remote server (`~/.ssh/authorized_keys`) -- only after the new Mac's key is confirmed working
- Copy over anything machine-local you want (e.g. `~/Development`, fonts, SSH keys).
