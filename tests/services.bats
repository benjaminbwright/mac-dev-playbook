#!/usr/bin/env bats
# Tests for issue #11: services, LaunchAgents, and login items.
# Run with: bats tests/

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO
  # Galaxy roles land in different places depending on how they were installed.
  export ANSIBLE_ROLES_PATH="$REPO/.ansible/roles:$REPO/roles:$HOME/.ansible/roles"
  export ANSIBLE_DEPRECATION_WARNINGS=False
  TMP="$(mktemp -d)"
  export TMP
}

teardown() {
  rm -rf "$TMP"
}

@test "default.config.yml declares service and login-item settings" {
  run python3 - "$REPO/default.config.yml" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
assert cfg["configure_active_git_agent"] is False, cfg.get("configure_active_git_agent")
assert cfg["homebrew_services_started"] == ["mysql", "mongodb-community", "syncthing"], cfg.get("homebrew_services_started")
names = [item["name"] for item in cfg["login_items"]]
assert names == ["Dropbox", "Google Drive", "Claude"], names
assert all(item["path"].startswith("/Applications/") for item in cfg["login_items"])
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "main.yml includes tasks/services.yml under the services tag" {
  [ -f "$REPO/tasks/services.yml" ]
  run ansible-playbook "$REPO/main.yml" --list-tasks --tags services
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ensure configured Homebrew services are started"*"TAGS: [services]"* ]]
}

@test "active-git LaunchAgent template renders a valid plist with a stable node path" {
  run ansible localhost -i localhost, -c local -m template \
    -a "src=$REPO/templates/com.active-git.plist.j2 dest=$TMP/com.active-git.plist" \
    -e '{"ansible_env": {"HOME": "/Users/example"}}'
  [ "$status" -eq 0 ]
  run plutil -lint "$TMP/com.active-git.plist"
  [ "$status" -eq 0 ]
  run python3 - "$TMP/com.active-git.plist" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
assert p["Label"] == "com.active-git", p["Label"]
assert p["ProgramArguments"] == ["/opt/homebrew/bin/node", "/opt/homebrew/bin/active-git"], p["ProgramArguments"]
assert p["WorkingDirectory"] == "/Users/example/active-git", p["WorkingDirectory"]
assert p["StartCalendarInterval"] == {"Minute": 5}, p["StartCalendarInterval"]
assert p["RunAtLoad"] is True
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "login items are read and only missing ones added, under the services tag" {
  run ansible-playbook "$REPO/main.yml" --list-tasks --tags services
  [ "$status" -eq 0 ]
  [[ "$output" == *"Read the current login items"*"TAGS: [services]"* ]]
  [[ "$output" == *"Add missing login items"*"TAGS: [services]"* ]]
  # The add step must be gated on the item being absent from the current list.
  run python3 - "$REPO/tasks/services.yml" <<'PY'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
def walk(items):
    for t in items:
        yield t
        yield from walk(t.get("block", []))
add = next(t for t in walk(tasks) if t["name"].startswith("Add missing login items"))
when = " ".join(add["when"]) if isinstance(add["when"], list) else add["when"]
assert "login_items_current" in when and "not in" in when, when
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "MySQL root task is skipped in check mode and gated on a live-server probe" {
  run ansible-playbook "$REPO/main.yml" --list-tasks
  [ "$status" -eq 0 ]
  [[ "$output" == *"Probe whether MySQL is accepting connections"* ]]
  run python3 - "$REPO/main.yml" <<'PY'
import sys, yaml
play = yaml.safe_load(open(sys.argv[1]))[0]
tasks = play["tasks"]
probe = next(t for t in tasks if t.get("name", "").startswith("Probe whether MySQL"))
assert "mysqladmin" in probe["ansible.builtin.command"]["cmd"], probe
assert "mysql_ping" == probe["register"], probe
root = next(t for t in tasks if t.get("name", "").startswith("Setup root MySQL user"))
when = root["when"] if isinstance(root["when"], list) else [root["when"]]
assert any("not ansible_check_mode" in w for w in when), when
assert any("mysql_ping" in w for w in when), when
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "services files pass yamllint, ansible-lint and the playbook syntax check" {
  run yamllint --strict -c "$REPO/.yamllint" "$REPO/tasks/services.yml" "$REPO/default.config.yml" "$REPO/main.yml"
  [ "$status" -eq 0 ]
  run ansible-lint --offline "$REPO/tasks/services.yml"
  [ "$status" -eq 0 ]
  run ansible-playbook "$REPO/main.yml" --syntax-check
  [ "$status" -eq 0 ]
}
