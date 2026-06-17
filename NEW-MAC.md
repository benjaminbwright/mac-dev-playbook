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
```bash
pip3 install --upgrade pip
pip3 install ansible
```

`pip3` installs the `ansible*` commands into your Python **user bin** directory,
which is not on `PATH` by default — so you'll see a warning like
*"installed in '/Users/you/Library/Python/3.x/bin' which is not on PATH"* and
`ansible-playbook` won't be found. Add that directory to your PATH. Deriving it
dynamically survives Python version upgrades (the version number changes per
machine, e.g. 3.9 on a fresh Mac's bundled Python):

```bash
# Make it permanent (zsh is the macOS default shell):
echo 'export PATH="$(python3 -m site --user-base)/bin:/opt/homebrew/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# Confirm it worked:
which ansible        # -> .../Library/Python/3.x/bin/ansible
ansible --version
```

> If you'd rather install Ansible via Homebrew once it's available
> (`brew install ansible`), its commands land in `/opt/homebrew/bin`, which is
> already on PATH — no extra step needed.

### 6. Clone this repo
```bash
git clone git@github.com:benjaminbwright/mac-dev-playbook.git
cd mac-dev-playbook
```
No SSH keys on the new machine yet? Use HTTPS:
`git clone https://github.com/benjaminbwright/mac-dev-playbook.git`

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

**App Store apps fail ("Required `mas` tool is not installed", or fatal under the mas role)**
The `geerlingguy.mac.mas` 5.0.0 role runs `mas` as **root** (`become: true`), but
`mas` works against *your* signed-in App Store session — root has no Apple ID, so
it fails (and sudo's PATH reset also hides the `mas` binary). This repo therefore
**disables that role** and installs App Store apps as your user via
[tasks/mas.yml](tasks/mas.yml). Pull the latest if you still see the role running.

`mas` can only install apps **already in your Apple ID's library** — it never
first-time "Gets" or purchases. Paid apps (Logic Pro, MainStage, Sketch) must be
bought once in the App Store; after that they install automatically. `tasks/mas.yml`
does not fail the play on an app it can't install — it prints which ones to grab
by hand.

## Good to know

- [main.yml](main.yml) starts MySQL/MongoDB services, sets a root MySQL password
  (`root`/`root`), and runs `rustup-init`. Expected behavior.
- Override anything in `default.config.yml` by creating a `config.yml` (gitignored,
  globbed by `main.yml` pre_tasks) — see [README.md](README.md).

## Decommissioning the old Mac

Before wiping it:
- Sign out of Adobe Creative Cloud
- Sign out of Panic Sync in Transmit
- Deauthorize Apple Music
- Copy over anything machine-local you want (e.g. `~/Development`, fonts, SSH keys).
