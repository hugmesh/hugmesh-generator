"""Base CA certificate FIXTURES for the #335 tests (GUI picker, TUI 'c' command,
the shared ``config.ca_cert_error`` / ``describe_ca_cert`` predicates).

Why a .py file that WRITES the PEMs instead of two .pem files in tests/data: the
repo's .gitignore carries a blanket ``*.pem`` rule, which exists to keep key material
out of the tree. These are public certificate halves with no private key — their keys
were written to /dev/null at generation and do not exist anywhere — but ``git add -f``
past a rule that is there to stop secrets leaking is a bad habit to teach the next
person, and renaming them to dodge the glob is worse. Carrying the text here keeps
the fixtures IN the repo, honestly, under a name the rule was never about.

They are REAL self-signed X.509 certificates, so the tests exercise the actual parse
path (and, where python-cryptography is installed, the real subject/expiry read)
rather than a stub that only looks like a PEM. Valid to 2126 so the suite cannot
start failing on a fixture that quietly expired.

Import ``CA_ROOT`` / ``CA_ALT`` for paths; they are materialised once per test
process into a temp dir that is removed at exit.
"""
import atexit
import os
import shutil
import tempfile

#: subject CN=HugMesh Studio Test Root CA, O=HugMesh Studio Tests; notAfter 2126.
CA_ROOT_PEM = """\
-----BEGIN CERTIFICATE-----
MIIDbTCCAlWgAwIBAgIUH24qLJsZ8vs12QI7PW4OQFjNXNcwDQYJKoZIhvcNAQEL
BQAwRTEkMCIGA1UEAwwbSHVnTWVzaCBTdHVkaW8gVGVzdCBSb290IENBMR0wGwYD
VQQKDBRIdWdNZXNoIFN0dWRpbyBUZXN0czAgFw0yNjA5MTAwNzE2MTJaGA8yMTI2
MDgxNzA3MTYxMlowRTEkMCIGA1UEAwwbSHVnTWVzaCBTdHVkaW8gVGVzdCBSb290
IENBMR0wGwYDVQQKDBRIdWdNZXNoIFN0dWRpbyBUZXN0czCCASIwDQYJKoZIhvcN
AQEBBQADggEPADCCAQoCggEBANI7QyFfI3HWQnMcxS95LdNK8Jw1PCrdz6aEXHHr
LPmc0bmZXEUt/Sx9Y5HegReAAdTfQOj/W3RXG4+yUJ8zrcxn6JfeUyHf4sIN3bh+
3tTqxs0XVhdZlNlFrkLXPe+0eSYe4sA2twl31cXiY4ZoRFXHsy3mP679GimYnJX6
WhqlpQgsXl/3qBM8AYtX3nNCLin8o3SRY+8WZIqPmMFZH4uaq90N/mb6l1Bw1qT2
2/eZjpReySGcbKZ91WkQE1KIEvSLkILv/6oSufv1p05Y9cAmh77o+GY0b0X5e1L4
mhaZ6RV9RzUGes6ptoLsC9RwpnWjA+iJFwxieA0Si4ANoFECAwEAAaNTMFEwHQYD
VR0OBBYEFILwzeQ7Mqh+f/UOzdg8QSfYqR0mMB8GA1UdIwQYMBaAFILwzeQ7Mqh+
f/UOzdg8QSfYqR0mMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEB
ACABuX7dsHsd7BNXUXQHWdM3sCUYnFFDqj/tO5Voy1fU0MBqxZu0KDpyNm8GnlmT
aV97SaVkbikaemF6blrZj729Y934Ca8908Roq4Ywqc1zmQkx+gkvCFmtcu4gnyqw
jTyQugQBfYII2fnMH2UcSIy/xAnZA88uEPX/dnNFAt0OQlq188HMrkHoloxmNbXD
orgJ5p+7UEVraYI9bV9OC6jNIESVyr/KfgA3dBbQ/6Zn4NXTl5FSC3zrd9av4CfQ
+9fTqwqbgmG1RWhl2BI+zzQveWE+LpBgknv8tD8mA3AdiePV5N37OcnGMThEX4UR
mR9noCxrWoMmAJKLoCaSkjE=
-----END CERTIFICATE-----
"""

#: subject CN=HugMesh Studio Test Alt CA, O=HugMesh Studio Tests; notAfter 2126.
CA_ALT_PEM = """\
-----BEGIN CERTIFICATE-----
MIIDazCCAlOgAwIBAgIUboOJQ/N4NH00ulGy53PUvndTOtIwDQYJKoZIhvcNAQEL
BQAwRDEjMCEGA1UEAwwaSHVnTWVzaCBTdHVkaW8gVGVzdCBBbHQgQ0ExHTAbBgNV
BAoMFEh1Z01lc2ggU3R1ZGlvIFRlc3RzMCAXDTI2MDkxMDA3MTYxMloYDzIxMjYw
ODE3MDcxNjEyWjBEMSMwIQYDVQQDDBpIdWdNZXNoIFN0dWRpbyBUZXN0IEFsdCBD
QTEdMBsGA1UECgwUSHVnTWVzaCBTdHVkaW8gVGVzdHMwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQCQfBZQqq+2eaTx4CBLgUMAeOumYXu+F8GO48/V9TWW
nhKCPe4rW4/M2bNRTH070UweY33a78Z3h+KwxJddYFpkiWIJZpyielaQhq7s3E+0
N/AXHZvtKjPS982fNmLIryaWWJWFRYJi6yD2y+OSvwfzapidANVwea3INddFhcG2
6/i0IgEZHdgK0eG+yHel3+lOmhGPbOp968f8t9xgNCLCNIwa61Jlng76BbcY6bBH
jhhV3P9ZWQM4EBXXU9AAzfKPQl8Vc1edxcBvzUd2LlVFbvo6R6+pNp/+FUmGS1uL
mWYXWp8f/v16n6OsWONfu320bGKCkh4Ncb72bMCMboX1AgMBAAGjUzBRMB0GA1Ud
DgQWBBTjfeZ60J72v6PMWkZ70b8nGoKFrDAfBgNVHSMEGDAWgBTjfeZ60J72v6PM
WkZ70b8nGoKFrDAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQAw
COdPEZbsiDHhlWx/tpMU5F8vARLZLgW6VUv8MjWmTM4skndpEmwYlVgRoHRQepjo
ZJ+z3sqqnfj6yeTFITZ4YklhJpixhdixEy9OOW/KJ/D08c75RCyBJUinxKl+yMbb
mZ0abGJEzCJM6LGccCV4UVM/92rKSKg+F0r1ZwWPBfGEXUYX02lt/mM3XlF5Dp3r
xM5ftw3/dM5IqUXH1xys8Dwm7x0pBUetBx1Jn/3LKbn5mFNRUiTC62Nryx+/XsE2
lH6ZCX5717fpUyVhAzR1FgYaxVP8Ppm8An/6g3Ujlz/W5SAaGqJtWwTMVizdIeqG
VXjkmoOJF1c2iUrrf9rQ
-----END CERTIFICATE-----
"""

CA_ROOT_SUBJECT_CN = "HugMesh Studio Test Root CA"
CA_ALT_SUBJECT_CN = "HugMesh Studio Test Alt CA"
CA_EXPIRY_YEAR = "2126"

_DIR = tempfile.mkdtemp(prefix="hugmesh-studio-ca-fixtures-")
atexit.register(shutil.rmtree, _DIR, True)


def _write(name: str, text: str) -> str:
    path = os.path.join(_DIR, name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return path


#: A file that really parses as an X.509 certificate.
CA_ROOT = _write("ca-root.pem", CA_ROOT_PEM)
#: A second one, so "which of them did this domain pick" is a real question.
CA_ALT = _write("ca-alt.pem", CA_ALT_PEM)
