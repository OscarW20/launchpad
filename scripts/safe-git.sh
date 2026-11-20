# Sourced by update.sh, make-app.sh and release.sh: git the way the app runs it (UpdateCheck.hardenedGitArguments).
#
# These scripts run outside the bot sandbox, in a checkout that bots may be able to write. So nothing in that checkout
# (a hook, a program-running key in .git/config such as a filesystem monitor or a credential helper) may run, and
# nothing in the environment may redirect git (GIT_DIR, GIT_SSH_COMMAND, GIT_EXEC_PATH, GIT_CONFIG_*…).
#
# Your own global git config is ignored too, unless LAUNCHPAD_GIT_USE_GLOBAL=1 is set before sourcing (release.sh needs
# your identity to tag, and the GitHub sign-in to push).

for _name in $(compgen -e); do
  case "$_name" in GIT_*) unset "$_name" ;; esac
done
unset _name
export GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0
if [[ -z "${LAUNCHPAD_GIT_USE_GLOBAL:-}" ]]; then
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
fi

# The same settings as environment config, which every git started below this one inherits and which outranks the
# checkout's own .git/config. Without it, `swift build` (which runs git in the checkout itself) would still run a
# filesystem monitor planted there. The credential helper is only reset when your global config is ignored: release.sh
# pushes with the GitHub CLI's helper (git_gh), set explicitly on that one command.
_n=0
_set() { export "GIT_CONFIG_KEY_$_n=$1" "GIT_CONFIG_VALUE_$_n=$2"; _n=$((_n + 1)); }
_set core.hooksPath /dev/null
_set core.fsmonitor ""
_set core.sshCommand ssh
_set protocol.ext.allow never
_set protocol.file.allow never
_set http.sslVerify true
_set http.proxy ""
if [[ -z "${LAUNCHPAD_GIT_USE_GLOBAL:-}" ]]; then _set credential.helper ""; fi
export GIT_CONFIG_COUNT="$_n"
unset _n
unset -f _set

git() {
  command git -c core.hooksPath=/dev/null -c core.fsmonitor= -c credential.helper= -c core.sshCommand=ssh \
    -c protocol.ext.allow=never -c protocol.file.allow=never -c core.pager=cat -c core.editor=true "$@"
}

# git with the GitHub CLI's sign-in as the only credential helper, for the one command that needs to push (a tag).
git_gh() { git -c 'credential.helper=!gh auth git-credential' "$@"; }

# Succeeds only if origin is Launchpad's own repository and the checkout doesn't rewrite URLs (a `url.<base>.insteadOf`
# would send even a trusted address somewhere else). The same rule as UpdateCheck.isTrustedRemote.
trusted_origin() {
  local url https_form ssh_form ssh_url_form
  https_form='^https://github\.com/oscarw20/launchpad(\.git)?/?$'
  ssh_form='^git@github\.com:oscarw20/launchpad(\.git)?$'
  ssh_url_form='^ssh://git@github\.com/oscarw20/launchpad(\.git)?/?$'
  url="$(git remote get-url origin 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  [[ "$url" =~ $https_form || "$url" =~ $ssh_form || "$url" =~ $ssh_url_form ]] || return 1
  if git config --local --get-regexp '^url\.' >/dev/null 2>&1; then return 1; fi
  return 0
}
