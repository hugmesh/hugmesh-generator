
# --- hugmesh-akkoma (images/akkoma/hugmesh-env.sh, appended to rel/env.sh.eex) ---
# bin/pleroma sources this file for EVERY release command (start, eval, rpc, and
# pleroma_ctl through them) before it reads releases/COOKIE. The release step
# bakes a random cookie into releases/COOKIE, which in a published image is public
# to anyone who pulls it, so the image ships none (the Dockerfile deletes it).
# Unless RELEASE_COOKIE is set, each container mints its own the first time any
# release command runs, and every later command in the same container (pleroma_ctl
# over rpc, `kubectl exec`) reads the same file. `ln` publishes it atomically, so
# two first commands racing still agree on one cookie.
if [ -z "${RELEASE_COOKIE:-}" ]; then
  _hm_dir="${RELEASE_TMP:-/tmp}"
  _hm_cookie="$_hm_dir/hugmesh-akkoma.cookie"
  if [ ! -s "$_hm_cookie" ]; then
    _hm_new="$_hm_dir/hugmesh-akkoma.cookie.$$"
    (umask 077 && od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$_hm_new")
    ln "$_hm_new" "$_hm_cookie" 2>/dev/null || :
    rm -f "$_hm_new"
  fi
  RELEASE_COOKIE="$(cat "$_hm_cookie")"
  export RELEASE_COOKIE
  unset _hm_dir _hm_cookie _hm_new
fi
