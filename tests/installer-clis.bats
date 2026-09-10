#!/usr/bin/env bats
# Checks that the installer-based CLI step (GitHub issue #10) is wired into the
# playbook and selectable by tag. Only inspects the playbook (--list-tasks);
# nothing is installed. Needs the Galaxy roles from requirements.yml resolvable
# (./roles, or ANSIBLE_ROLES_PATH) exactly like `--syntax-check` does.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  cd "$REPO_ROOT"
}

@test "installer-clis tag selects the pocket-server installer task" {
  run ansible-playbook main.yml --list-tasks --tags installer-clis
  [ "$status" -eq 0 ]
  [[ "$output" == *"pocket-server"* ]]
  [[ "$output" == *"[installer-clis]"* ]]
}

# The tools Homebrew now provides are declared as regular config entries.
@test "default.config.yml declares codex and cursor-cli casks and the turso formula" {
  # Force JSON results (ansible.cfg renders YAML) so items appear quoted.
  ANSIBLE_CALLBACK_RESULT_FORMAT=json \
    run ansible localhost -m debug -a "msg={{ homebrew_cask_apps + homebrew_installed_packages }}" -e @default.config.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *'"codex"'* ]]
  [[ "$output" == *'"cursor-cli"'* ]]
  [[ "$output" == *'"turso"'* ]]
}

@test "NEW-MAC.md documents the installer-based CLIs step and the guard command" {
  run grep -c '^## Installer-based CLIs' NEW-MAC.md
  [ "$output" = "1" ]
  run grep -F 'scripts/guard-shell-rc.sh ~/Development/GitHub/dotfiles/.zshrc' NEW-MAC.md
  [ "$status" -eq 0 ]
}
