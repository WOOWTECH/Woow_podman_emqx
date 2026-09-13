# shellcheck shell=bash
# scripts/legacy-common.sh: the rollback helpers scripts/migrate-legacy.sh uses to keep the legacy
# containers available (STANDARD 7a). Sourced after scripts/common.sh. Kept out of common.sh on
# purpose: that file is the one this repo shares verbatim with the other Quadlet repos.
#
# Two shapes, decided by ql_rollback_strategy from the host's real state and never from its name:
#
#   rename   podman rename <name> <name>-legacy-<suffix>, left stopped. Safe only while nothing
#            starts it again.
#   capture  ql_capture_container into the backup directory, then a plain `podman rm`. Needed where
#            the user unit podman-restart.service is enabled AND a legacy container's restart policy
#            is exactly `always` - podman 4.9.3 cannot change a policy in place, so a renamed copy
#            would revive at the next boot and fight the new Quadlet container for its name, ports
#            and volumes. woow-emqx is that container on woowtechopenclaw.
#
# What capture-then-remove cannot preserve is the container's writable layer. LEGACY_COMMIT_ALWAYS
# names the containers whose own deploy or upgrade script writes into the running container, and
# LEGACY_COMMIT_RW_BYTES is the measured size above which any container is committed anyway. Both
# are set in scripts/common.sh, so the decision is per repo, visible, and testable.

# app_unlocked <cmd...>: run <cmd> with the app lock's file descriptor closed.
#
# ql_lock takes the per-app lock with `exec {fd}>"$dir/lock"`, and bash does not mark a descriptor
# opened that way close-on-exec. Every child therefore inherits it - including conmon and
# rootlessport, which outlive the script and keep the flock for as long as the container runs. The
# next install, upgrade, uninstall or --rollback for this app then dies with "another
# install/upgrade/uninstall is running". Verified on toypark1234, where both the emqx and the odoo18
# locks were held by a conmon that had inherited them.
#
# Until quadlet-lib closes that descriptor itself, everything that can start a container runs
# through here. A missing QL_LOCK_FD (no lock taken) just runs the command.
app_unlocked() {
  if [[ -n ${QL_LOCK_FD:-} ]]; then
    eval '"$@" '"$QL_LOCK_FD"'>&-'
  else
    "$@"
  fi
}

# app_volume_identity <volume>: "<mountpoint>|<createdat>|<inode>". The three facts that prove the
# Quadlet unit adopted this very volume instead of silently creating a fresh one (which is what a
# .volume without VolumeName= would have done - it would be called systemd-<name>).
app_volume_identity() {
  local v=$1 line mp ca ino
  line=$(podman volume inspect --format '{{.Mountpoint}}|{{.CreatedAt}}' "$v" 2>/dev/null) || return 1
  line=${line%%$'\n'*}
  mp=${line%%|*} ca=${line#*|}
  [[ -n $mp ]] || return 1
  # The volume directory may be owned by a container subuid, so ask inside the user namespace.
  ino=$(podman unshare stat -c %i -- "$mp" 2>/dev/null || echo '?')
  printf '%s|%s|%s' "$mp" "$ca" "$ino"
}

# app_legacy_rw_bytes <container>: the container's writable-layer size in bytes, '' when unknown.
# podman 4.9.3 needs --size for SizeRw; `podman diff` is NOT a substitute (on the live openclaw
# hermes-agent it printed an empty object while SizeRw was 42 672 686 bytes).
app_legacy_rw_bytes() {
  local rw
  rw=$(podman inspect --size --format '{{.SizeRw}}' "${1:?usage: app_legacy_rw_bytes <container>}" 2>/dev/null) || rw=''
  rw=${rw//[!0-9]/}
  printf '%s' "$rw"
}

# app_legacy_commit_wanted <container>: 0 when the capture of <container> must commit its writable
# layer first. Explains itself on stderr so a --dry-run reports the same decision the cutover makes.
app_legacy_commit_wanted() {
  local c=${1:?usage: app_legacy_commit_wanted <container>} rw n
  for n in ${LEGACY_COMMIT_ALWAYS:-}; do
    if [[ $n == "$c" ]]; then
      ql_info "$c: committing the writable layer at capture time (this stack writes into its own container)"
      return 0
    fi
  done
  rw=$(app_legacy_rw_bytes "$c")
  if [[ -z $rw ]]; then
    ql_warn "$c: cannot measure the writable layer; capturing without --commit, so files written inside the container and not in a volume would not come back"
    return 1
  fi
  if ((rw > ${LEGACY_COMMIT_RW_BYTES:-1048576})); then
    ql_info "$c: writable layer is $rw bytes (over ${LEGACY_COMMIT_RW_BYTES:-1048576}); committing it at capture time"
    return 0
  fi
  ql_info "$c: writable layer is $rw bytes; nothing worth committing"
  return 1
}

# app_legacy_capture <backup dir> <container>...: write the rollback copy of each container.
# Read-only towards the containers, so it belongs in the prepare phase, before any downtime: a
# container the library cannot replay (an empty CreateCommand - created through the podman API
# rather than the CLI) is refused here, while the legacy stack is still running.
app_legacy_capture() {
  local bk=${1:?usage: app_legacy_capture <backup dir> <container>...} c meta
  shift
  for c in "$@"; do
    meta=$bk/legacy-container/$c/meta
    if [[ -f $meta ]]; then
      ql_info "the rollback copy of $c is already in $bk/legacy-container/$c"
    elif app_legacy_commit_wanted "$c"; then
      ql_capture_container --commit "$c" "$bk" >/dev/null
    else
      ql_capture_container "$c" "$bk" >/dev/null
    fi
    [[ $(sed -n 's/^RECREATABLE=//p' "$meta" | tail -n1) == 1 ]] || ql_die \
      "$c was created through the podman API, not the CLI, so its create command cannot be replayed and a capture-based rollback is impossible. Either disable podman-restart.service (then the legacy containers can simply be renamed) or plan to rebuild $c by hand from $bk/legacy-container/$c/inspect.json"
  done
}

# app_legacy_retire <strategy> <suffix> <backup dir> <container>...: take the legacy containers out
# of the new stack's way, in the shape the strategy asked for.
app_legacy_retire() {
  # The suffix is empty on the capture path: nothing is renamed there, so there is no
  # <name>-legacy-<suffix> to name. ${2-} rather than ${2:?}, which would abort the script.
  local strategy=${1:?} sfx=${2-} bk=${3:?} c
  shift 3
  for c in "$@"; do
    case $strategy in
      rename)
        [[ -n $sfx ]] || ql_die "the rename path needs a suffix for $c-legacy-<suffix>"
        podman rename "$c" "$c-legacy-$sfx" || ql_die "podman rename $c failed"
        ql_info "renamed $c -> $c-legacy-$sfx (stopped, kept for --rollback)" ;;
      capture)
        [[ -f $bk/legacy-container/$c/meta ]] || ql_die "no rollback copy of $c in $bk; nothing was removed"
        # A plain rm on purpose: `podman rm -v` would delete the anonymous volumes that the capture
        # records and expects to find again.
        podman rm "$c" >/dev/null || ql_die "podman rm $c failed"
        ql_info "removed $c; --rollback recreates it from $bk/legacy-container/$c" ;;
      *) ql_die "unknown rollback strategy '$strategy'" ;;
    esac
  done
}

# app_legacy_restore <suffix> <backup dir> <container>...: bring the legacy containers back,
# whichever shape the cutover used. A recreated container comes back stopped and with its original
# restart policy; the caller starts it, exactly as it starts a renamed one.
app_legacy_restore() {
  # An empty suffix means the cutover captured rather than renamed: there is no
  # <name>-legacy-<suffix> to look for, only the rollback copy.
  local sfx=${1-} bk=${2:?} c
  shift 2
  for c in "$@"; do
    if [[ -n $sfx ]] && podman container exists "$c-legacy-$sfx"; then
      podman rename "$c-legacy-$sfx" "$c" || ql_die "podman rename $c-legacy-$sfx failed"
      ql_info "renamed $c-legacy-$sfx -> $c"
    elif [[ -f $bk/legacy-container/$c/meta ]]; then
      ql_recreate_container "$bk" "$c" >/dev/null || ql_die "could not recreate $c from $bk"
      ql_info "recreated $c from $bk/legacy-container/$c (stopped, with its original restart policy)"
    else
      ql_die "neither the renamed container ${sfx:+$c-legacy-$sfx }nor a rollback copy in $bk exists; restore $c by hand"
    fi
  done
}
