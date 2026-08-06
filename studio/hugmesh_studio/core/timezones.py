"""Offline timezone data for the wizard's System-identity step (ask 9).

The Timezone field used to be a free-text ``QLineEdit`` whose only guidance was a
placeholder ("Area/Location, e.g. Europe/Berlin"). A typo there reaches ``-T`` and
lands in ``/etc/timezone`` on the built image, so the operator asked for a DROPDOWN.

Everything here is read from the BUILD HOST at runtime — the system tz database and
``/etc/localtime`` / ``/etc/timezone`` / ``$TZ``. **No network, ever, and no bundled
zone list that could go stale**: :func:`available` asks :mod:`zoneinfo` (stdlib since
3.9, which reads ``/usr/share/zoneinfo`` or the ``tzdata`` wheel). Only when the host
has no tz database at all does it fall back to :data:`FALLBACK_ZONES`, a small curated
set that keeps the wizard usable instead of crashing — the documented "fall back
gracefully" arm, never the normal path.

Qt-free by design (``core/`` invariant): the page imports the two functions, the
combo is built there.
"""
from __future__ import annotations

import os

# The graceful-degradation list, used ONLY when the host has no tz database (a
# container built without sys-libs/timezone-data and without the tzdata wheel).
# Deliberately small and obviously curated — it is a lifeboat, not a zone table:
# one representative zone per UTC offset band plus UTC itself, so an operator can
# always pick something truthful for their fleet.
FALLBACK_ZONES = (
    "UTC",
    "Africa/Cairo", "Africa/Johannesburg", "Africa/Lagos", "Africa/Nairobi",
    "America/Anchorage", "America/Argentina/Buenos_Aires", "America/Bogota",
    "America/Chicago", "America/Denver", "America/Halifax", "America/Los_Angeles",
    "America/Mexico_City", "America/New_York", "America/Sao_Paulo", "America/Toronto",
    "Asia/Bangkok", "Asia/Dubai", "Asia/Hong_Kong", "Asia/Jakarta", "Asia/Jerusalem",
    "Asia/Kolkata", "Asia/Karachi", "Asia/Seoul", "Asia/Shanghai", "Asia/Singapore",
    "Asia/Tokyo",
    "Atlantic/Reykjavik",
    "Australia/Adelaide", "Australia/Brisbane", "Australia/Perth", "Australia/Sydney",
    "Europe/Amsterdam", "Europe/Berlin", "Europe/Dublin", "Europe/Helsinki",
    "Europe/Istanbul", "Europe/Lisbon", "Europe/London", "Europe/Madrid",
    "Europe/Moscow", "Europe/Paris", "Europe/Prague", "Europe/Rome",
    "Europe/Stockholm", "Europe/Warsaw", "Europe/Zurich",
    "Pacific/Auckland", "Pacific/Honolulu",
)

# The builders' own default when -T is omitted (TIMEZONE="UTC" in every builder:
# build-x86-host-stage4.sh:183, build-rpi5-stage4.sh:183, build-frite-stage4.sh:170,
# build-jetson-stage4.sh:162, build-orangepi5-stage4.sh:201, and the Zero/LTS twins).
DEFAULT_TIMEZONE = "UTC"

_ZONEINFO_ROOTS = ("/usr/share/zoneinfo", "/usr/lib/zoneinfo", "/etc/zoneinfo")


def available() -> list[str]:
    """Every IANA zone name this HOST knows, sorted, with ``UTC`` first.

    Reads the system tz database through :mod:`zoneinfo` — no network, no bundled
    copy. Returns :data:`FALLBACK_ZONES` when the host has no tz database at all
    (``ZoneInfoNotFoundError``/``ImportError``), so the dropdown degrades instead of
    the page failing to build.
    """
    try:
        import zoneinfo                       # stdlib >= 3.9
        zones = set(zoneinfo.available_timezones())
    except Exception:
        # ANY failure here is a fall-back, not a crash: this runs inside a Qt page
        # constructor and under PyQt6 an escaping exception is qFatal.
        return list(FALLBACK_ZONES)
    if not zones:
        return list(FALLBACK_ZONES)
    zones.add(DEFAULT_TIMEZONE)
    rest = sorted(z for z in zones if z != DEFAULT_TIMEZONE)
    return [DEFAULT_TIMEZONE, *rest]


def _from_localtime_symlink() -> str:
    """The zone named by ``/etc/localtime`` when it is a symlink into a zoneinfo tree
    (the systemd/OpenRC norm) — e.g. ``/usr/share/zoneinfo/Europe/Berlin`` ->
    ``Europe/Berlin``. "" when it is a plain copied file (no name to recover)."""
    try:
        target = os.path.realpath("/etc/localtime")
    except OSError:
        return ""
    for root in _ZONEINFO_ROOTS:
        prefix = root.rstrip("/") + "/"
        if target.startswith(prefix):
            name = target[len(prefix):]
            # posix/ and right/ are alternate encodings of the same zones; strip the
            # prefix so the name matches what available() offers.
            for alt in ("posix/", "right/"):
                if name.startswith(alt):
                    name = name[len(alt):]
            return name
    return ""


def host_timezone() -> str:
    """This build host's timezone as an IANA name, or ``"UTC"``.

    Probe order — most explicit first: ``$TZ`` (an operator override that the shell
    already honours), ``/etc/timezone`` (Debian/Gentoo one-line file),
    ``/etc/localtime``'s symlink target. Never raises; never touches the network.

    The value is only a DEFAULT for the field: it is what the operator most likely
    wants baked, not a claim about the target hardware's location.
    """
    tz = (os.environ.get("TZ") or "").strip().lstrip(":")
    if tz:
        return tz
    try:
        with open("/etc/timezone", encoding="utf-8") as fh:
            tz = fh.read().strip()
        if tz:
            return tz
    except OSError:
        pass
    return _from_localtime_symlink() or DEFAULT_TIMEZONE


def default_timezone() -> str:
    """The zone the System step preselects: the host's zone when this host's tz
    database actually knows it, else UTC.

    The extra membership check matters — a ``$TZ`` of ``EST5EDT`` or a stale
    ``/etc/timezone`` naming a zone the target has never heard of would otherwise be
    preselected and baked into every image, and ``-T`` is not validated by the
    builders beyond the identity allowlist (``core/config.py`` ``_TIMEZONE_RE``).
    """
    tz = host_timezone()
    return tz if tz in available() else DEFAULT_TIMEZONE
