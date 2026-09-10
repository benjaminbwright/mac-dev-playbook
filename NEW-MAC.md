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
to `~/Development/GitHub/dotfiles` and symlinks the tracked files into `~`.
Run just that part with `--tags dotfiles`. Two lists in
[default.config.yml](default.config.yml) say what gets linked:

- `dotfiles_files` — top-level files, linked by the `geerlingguy.dotfiles` role:
  `.zshrc`, `.aliases`, `.gitconfig`, `.gitignore`, `.inputrc`, `.vimrc`, `.osx`,
  `.zshenv`, `.zprofile`, `.bashrc`, `.profile`, `.roku-remote.yaml`,
  `.jest-audio-reporterrc`.
- `dotfiles_nested_files` — paths with a directory component, linked by
  [tasks/dotfiles-nested.yml](tasks/dotfiles-nested.yml) (the role only does
  top-level files): `.ssh/config`, `.warp/keybindings.yaml`,
  `.warp/themes/matrix.yaml`, `.config/git/ignore`, `.aws/config`,
  `.cursor/mcp.json`, `.codex/config.toml`. A path that isn't in the clone yet
  is skipped, so the step is safe before you've captured it.

Both lists link the file at the same relative path (`~/.ssh/config` →
`<clone>/.ssh/config`). An existing plain file in `~` is **replaced** by the
link — e.g. the `brew shellenv` line step 4 appended to `~/.zprofile` goes away,
which is fine because the tracked `.zshrc` already puts `/opt/homebrew/bin` on
PATH. SSH **keys** are never in the repo: hand-carry `~/.ssh/id_*` from the old
Mac (`.ssh/config` references `~/.ssh/id_m1macbook`) and `chmod 600` them.

### Capturing dotfiles from the old Mac
Before the migration, on the **old** Mac, copy the files in both lists into the
clone and commit them (the playbook only ever goes clone → `~`, not back):

```bash
cd ~/ansible/mac-dev-playbook
scripts/capture-dotfiles.sh                 # copies ~ -> ~/Development/GitHub/dotfiles
git -C ~/Development/GitHub/dotfiles status # review what landed
git -C ~/Development/GitHub/dotfiles add -A && git -C ~/Development/GitHub/dotfiles commit -m "Track shell/tool dotfiles" && git -C ~/Development/GitHub/dotfiles push
ansible-playbook main.yml --ask-become-pass --tags dotfiles   # ~ now symlinks into the clone
```

`scripts/capture-dotfiles.sh --list` prints the list it uses (it reads the two
variables above, so script and playbook can't drift). It is idempotent, skips
files that aren't on this machine, and **refuses to copy any file whose contents
match a credential pattern** (password/token/cookie/API key/private key…),
printing a `WARN` instead — those belong in the secrets repo. Pass explicit
paths to capture just some: `scripts/capture-dotfiles.sh .zprofile .ssh/config`.

### `.netrc` and other `$HOME` secrets → the secrets repo
`~/.netrc` (Heroku credentials), `~/.prismic`, `~/.squarespace-local-developer`,
`~/.codex/auth.json` and `~/.aws/{cli,sso}` are **not** dotfiles: they hold
tokens/cookies and must stay out of the dotfiles repo (the capture script skips
them). Keep `.netrc` in the vault-encrypted
[secrets repo](https://github.com/benjaminbwright/secrets) instead; its
`make restore` writes every bundled file to `~/<dest>` with mode `0600`, which
is exactly what `.netrc` needs. Its scanner only finds gitignored `.env*` files
inside repos, so add `.netrc` explicitly, on the old Mac:

```bash
cd ~/Development/GitHub/secrets
make edit        # ansible-vault edit: append under repo_secret_files:
                 #   - dest: .netrc
                 #     content: |
                 #       <paste the lines of ~/.netrc, indented>
git commit -am "Add ~/.netrc (Heroku) to the secrets bundle" && git push
```

> `make update` rebuilds the bundle from the `sources.txt` scan and would drop a
> hand-added entry. To make it stick, teach `bin/build-bundle.py` to accept
> **file** lines in `sources.txt` (e.g. `~/.netrc`) alongside folders — see the
> PR for issue #8 for the three-line patch — then just list `~/.netrc` there.

On the **new** Mac, `.netrc` comes back with the rest of the secrets (`make
restore`, see "Repo secrets" below). Re-log into the other tools by hand
(`heroku login` also regenerates `.netrc`; `aws sso login`; Codex/Prismic/
Squarespace sign-in).

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
Your global Claude config is snapshotted in the private dotfiles repo and restored
by the `--tags claude` step ([tasks/claude.yml](tasks/claude.yml)). Everything is
**seeded** (never overwrites a machine that already has settings/skills) and every
piece is optional, so a partial snapshot never fails the run. What's restored:

| Live location | Snapshot (dotfiles repo) | How it's restored |
|---|---|---|
| `~/.claude/settings.json`, `settings.local.json`, `config.json` | `claude/` | copied if missing |
| `~/.agents/.skill-lock.json` (skills installed by the `skills` CLI) | `claude/skill-lock.json` | `npx skills add` per skill missing from `~/.claude/skills`, symlinked into `claude-code` + `pi` (`claude_skills_agents`) |
| hand-made skills (`descript-cut`, `issue-train`, `merge-train`, `rolling-train`) | `claude/skills/<name>/` | rsync, adds missing only |
| `~/.pi/agent/settings.json` | `pi/agent/settings.json` | copied if missing |
| plugins `gopls-lsp` (user) and `figma` (project `~/praxis-loop/nmohm-web`) | not snapshotted | `claude plugin install` (`claude_plugins_user` / `claude_plugins_project` in `default.config.yml`); project-scope only if the project dir exists — re-run `--tags claude` after cloning it |

**Re-capture on the old Mac** (idempotent, deletes nothing, then review + commit):

```bash
scripts/capture-claude.sh            # defaults to ~/Development/GitHub/dotfiles
DF=~/Development/GitHub/dotfiles
git -C "$DF" status                  # it prints `git rm` hints for stale skill copies now covered by the lock file
git -C "$DF" add -A claude pi && git -C "$DF" commit -m "Update Claude config snapshot" && git -C "$DF" push
```

`settings.json` is captured as-is, including its large `permissions.allow` list
(many rules reference paths on the old Mac). Pruning it is a manual judgement call —
edit the copy in the dotfiles repo before committing if you want a leaner start.

**Hand-carry (not in the snapshot):** `~/.claude.json` holds your OAuth tokens plus
the `Jam` MCP server and per-project state. Copy it over directly (AirDrop /
encrypted disk) or sign in again and re-add the MCP server with `claude mcp add`.
`~/.pi/agent/auth.json` is likewise a secret — hand-carry or re-authenticate.

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

## Language toolchains

Toolchains that live outside Homebrew are reproduced by
[tasks/toolchains.yml](tasks/toolchains.yml); the lists live in
[default.config.yml](default.config.yml) under **LANGUAGE TOOLCHAINS**. It runs
last in the full playbook (it needs brew's managers and `rustup-init`), or alone:

```bash
ansible-playbook main.yml --ask-become-pass --tags toolchains
```

| Manager | Installs | Guard (re-runs are no-ops) |
|---|---|---|
| nvm | Node `20` (default) and `24` | `~/.nvm/versions/node/v<ver>*` exists |
| pyenv | Python 3.10.13, set as `pyenv global` | `~/.pyenv/versions/<ver>` exists |
| `go install` | gopls, golangci-lint, staticcheck, goimports, govulncheck, gosec, protoc-gen-go, go-jsonschema, amtool | `~/go/bin/<name>` exists |
| cargo | mdbook, wasm-pack | `~/.cargo/bin/<name>` exists |
| pipx | ansible-lint, yamllint | `~/.local/bin/<name>` exists |
| `npm -g` (nvm default Node) | `@playwright/mcp` | package dir under the default Node |
| Homebrew `python3 -m pip` | pypdf, pillow, Jinja2, PyYAML (`--break-system-packages`) | pip's own "already satisfied" |

Everything installs as your user (never `become`), and every task is
idempotent, so `--tags toolchains` is safe to re-run after editing a list.

Decisions you may want to revisit:
- **Node trimmed** from 16 / 18 / 20.x / 24 on the old Mac to `20` + `24`. Add
  `"16"` or `"18"` to `nvm_node_versions` if a project still needs them.
- **yarn globals dropped** (create-next-app, create-vite, turbo were 2023-era;
  use `npx`/`pnpm dlx` per project instead).
- **Local links skipped**: `issue-duck` (`npm link`) and `irep` (a project's own
  `go install`) are rebuilt from their repos, not listed here.
- **pnpm setup is opt-in** (`toolchains_pnpm_setup: true`). pnpm works
  per-project without it; `pnpm setup` is only for `pnpm add -g`, and it appends
  `PNPM_HOME` to `~/.zshrc`, which the dotfiles repo owns.

To re-capture the lists from a machine later:

```bash
ls ~/.nvm/versions/node; cat ~/.nvm/alias/default
pyenv versions
ls ~/go/bin              # module paths: go version -m ~/go/bin/<name> | grep path
cargo install --list
pipx list --short
npm ls -g --depth=0
/opt/homebrew/bin/python3 -m pip list --not-required
```

## Am I in sync? (`make audit`)

Every gap in this playbook was originally found by hand-diffing a Mac against the
config. `make audit` makes that repeatable. It is **read-only** (only `list`/`status`
commands and file reads — it never installs, writes or runs the playbook), so run
it on **both Macs during the overlap**, and any time afterwards:

```bash
make audit                                  # everything
scripts/audit.sh --section repo-state       # one section (see --help for the list)
scripts/audit.sh --strict                   # exit 1 if anything drifted (for scripts)
```

It prints drift in **both directions** for: Homebrew formulae/casks/taps, App Store
apps (`mas list` vs `mas_installed_apps`), VS Code/Cursor extensions plus a `diff` of
their settings files, Claude skills on disk vs `~/.agents/.skill-lock.json`, dotfiles
in `~` that aren't symlinks into the dotfiles repo, repos with no remote / not in
`git_repositories` / missing on disk, and repos with dirty, unpushed or stashed work.

- **Old Mac:** anything under `repos` / `repo-state` is work that will NOT transfer —
  push it, add the repo to `config.yml`, or hand-copy it. Anything "installed, not
  declared" is something to add to `default.config.yml` (or consciously drop).
- **New Mac:** after the playbook runs, "declared, not installed" is what still
  needs attention (usually an App Store sign-in, a manual install, or a failed step).

Repo scanning covers the top-level folders named in `git_repositories` plus
`~/Development`; override with `AUDIT_REPO_ROOTS=~/work:~/src make audit`.

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
