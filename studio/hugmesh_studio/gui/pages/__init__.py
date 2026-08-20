"""The image-build wizard's pages — one module per WIZARD_PAGE_SLUGS entry, in the
same order StudioWizard registers them (the fail-loud drift assert lives there).

golive.py is NOT part of this set: it is the separate go-live wizard's page module
(GOLIVE_PAGE_SLUGS) fronting scripts/go-live.sh, deliberately not imported here.
"""
from .welcome import WelcomePage
from .localmesh import LocalMeshDialog, LocalMeshPage
from .phone import PhoneDialog, PhonePage
from .quest import QuestDialog, QuestPage
from .deploy import DeployDialog, DeployPage
from .qemu import QemuPage
from .localcloud_nodes import LocalCloudNodesPage
from .mode import ModePage
from .idp import IdpPage
from .role import RolePage
from .worklist import WorklistPage
from .hardware import HardwarePage
from .branding import BrandingPage
from .network import NetworkPage
from .keyzip import KeyZipPage
from .domains_choice import DomainsChoicePage
from .domains import DomainsPage
from .users_choice import UsersChoicePage
from .users import UsersPage
from .system import SystemPage
from .home import HomePage
from .build import BuildPage
from .launch import LaunchPage

# ProgressPage lands in a later workstream (WS-REVIEWUI: gui/pages/progress.py). It is
# registered here defensively so the wizard's page registry slots it in the moment it
# exists and stays importable (as None) before then — the flow terminates on BuildPage
# until it lands.
try:
    from .progress import ProgressPage
except ImportError:                    # pragma: no cover — until WS-REVIEWUI lands it
    ProgressPage = None

__all__ = [
    "WelcomePage", "ModePage", "LocalMeshPage", "LocalMeshDialog",
    "PhonePage", "PhoneDialog", "QuestPage", "QuestDialog",
    "DeployPage", "DeployDialog", "QemuPage", "LocalCloudNodesPage", "IdpPage",
    "RolePage", "WorklistPage", "HardwarePage",
    "BrandingPage", "NetworkPage", "KeyZipPage",
    "DomainsChoicePage", "DomainsPage", "UsersChoicePage", "UsersPage",
    "SystemPage", "HomePage", "BuildPage", "LaunchPage", "ProgressPage",
]
