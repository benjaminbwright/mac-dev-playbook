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

### 4. Install Ansible
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

### 5. Clone this repo
```bash
git clone git@github.com:benjaminbwright/mac-dev-playbook.git
cd mac-dev-playbook
```
No SSH keys on the new machine yet? Use HTTPS:
`git clone https://github.com/benjaminbwright/mac-dev-playbook.git`

### 6. Install required roles/collections
```bash
ansible-galaxy install -r requirements.yml
```

### 7. Sanity-check first (recommended)
```bash
ansible-playbook main.yml --syntax-check
ansible-playbook main.yml --check --ask-become-pass --tags homebrew,mas
```
`--check` is a dry run — shows what would change without touching anything.

### 8. Run it
```bash
ansible-playbook main.yml --ask-become-pass
```
Enter your macOS password at the **BECOME** prompt. Homebrew installs automatically
on first run. Run subsets with tags, e.g.:
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
