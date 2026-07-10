"""The image-build wizard's pages — one module per WIZARD_PAGE_SLUGS entry, in the
same order StudioWizard registers them (the fail-loud drift assert lives there).

golive.py is NOT part of this set: it is the separate go-live wizard's page module
(GOLIVE_PAGE_SLUGS) fronting scripts/go-live.sh, deliberately not imported here.
"""
from .welcome import WelcomePage
from .mode import ModePage
from .role import RolePage
from .hardware import HardwarePage
from .branding import BrandingPage
from .network import NetworkPage
from .keyzip import KeyZipPage
from .domains import DomainsPage
from .users import UsersPage
from .system import SystemPage
from .home import HomePage
from .build import BuildPage

__all__ = [
    "WelcomePage", "ModePage", "RolePage", "HardwarePage", "BrandingPage",
    "NetworkPage", "KeyZipPage", "DomainsPage", "UsersPage", "SystemPage",
    "HomePage", "BuildPage",
]
