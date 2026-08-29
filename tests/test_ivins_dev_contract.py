from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class IvinsDevContractTests(unittest.TestCase):
    def test_installed_runtime_is_the_default(self):
        launcher = (ROOT / "dev.ps1").read_text(encoding="utf-8")
        command = (ROOT / "scripts" / "dev-command.ps1").read_text(encoding="utf-8")
        self.assertIn("[string]$IvinsRuntime = 'installed'", launcher)
        self.assertIn("[string]$IvinsRuntime = 'installed'", command)
        self.assertIn("Assert-IvinsInstalledRuntime", command)
        for setup in (
            "/opt/iros2j/setup.bash",
            "/opt/imavros/setup.bash",
            "/opt/vins/setup.bash",
            "/opt/vio_stack/current/local_setup.bash",
        ):
            self.assertIn(setup, command)

    def test_installed_mode_builds_only_the_newsim_adapter(self):
        builder = (ROOT / "scripts" / "wsl" / "build_vins_overlay.sh").read_text(
            encoding="utf-8"
        )
        installed = builder.split('if [[ "$runtime_mode" == installed ]]', 1)[1]
        installed = installed.split("else", 1)[0]
        self.assertIn('packages=(vins_sim_bringup)', installed)
        self.assertNotIn("third_party/VINS-NEO", installed)
        self.assertNotIn("third_party/iMAVROS", installed)
        self.assertNotIn("third_party/vio_stack", installed)

    def test_installed_runtime_gate_precedes_expensive_native_builds(self):
        command = (ROOT / "scripts" / "dev-command.ps1").read_text(encoding="utf-8")
        build = command.split("function Invoke-Build", 1)[1].split(
            "function Start-VinsStack", 1
        )[0]
        self.assertLess(
            build.index("Assert-IvinsInstalledRuntime"),
            build.index("Building Cosys-AirSim"),
        )
        self.assertIn("IVINS_RUNTIME_MISSING /usr/sbin/ivins-installer", command)

    def test_installed_runtime_requires_exact_newsim_product_manifest(self):
        command = (ROOT / "scripts" / "dev-command.ps1").read_text(encoding="utf-8")
        installed = command.split("function Assert-IvinsInstalledRuntime", 1)[1].split(
            "function Invoke-IvinsManagement", 1
        )[0]
        for contract in (
            "/usr/share/doc/ivins/release-manifest.json",
            "/usr/share/ivins/newsim-preflight.sh",
            'manifest["schema_version"] == 4',
            'manifest["release"]["version"] == "3.1.0.0"',
            'manifest["release"]["debian_version"] == "3.1.0.0-1+noble"',
            'manifest["supported_platforms"] == ["ubuntu24-amd64-newsim"]',
            'production_authorized"] is False',
        ):
            self.assertIn(contract, installed)
        self.assertLess(
            installed.index("/usr/share/ivins/newsim-preflight.sh"),
            installed.index("dpkg-query"),
        )

    def test_enrollment_secret_is_file_only_and_official_https(self):
        command = (ROOT / "scripts" / "dev-command.ps1").read_text(encoding="utf-8")
        management = command.split("function Invoke-IvinsManagement", 1)[1].split("function", 1)[0]
        self.assertIn("https://ivins.drone-age.org", management)
        self.assertIn("--key-file", management)
        self.assertNotIn("IvinsEnrollmentCode", command)
        self.assertNotIn("Tee-Object", management)

    def test_newsim_identity_is_stable_root_owned_and_setup_before_enrollment(self):
        command = (ROOT / "scripts" / "dev-command.ps1").read_text(encoding="utf-8")
        identity = (ROOT / "scripts" / "wsl" / "setup_ivins_newsim_identity.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("setup_ivins_newsim_identity.sh", command)
        self.assertIn("/etc/ivins/newsim-platform", command)
        self.assertIn("/etc/ivins/newsim-instance-id", command)
        self.assertIn("[[ -e $instance_file ]]", identity)
        self.assertIn("/proc/sys/kernel/random/uuid", identity)
        self.assertIn("root:root:444", identity)
        self.assertNotIn("machine-id >", identity)

    def test_update_flow_uses_iboot_local_intent(self):
        command = (ROOT / "scripts" / "dev-command.ps1").read_text(encoding="utf-8")
        self.assertIn("ivins-update-agent.service", command)
        self.assertIn("ibootctl update check", command)
        self.assertIn("ibootctl update status", command)
        self.assertIn("ibootctl update install", command)
        self.assertIn("^\\d+\\.\\d+\\.\\d+\\.\\d+$", command)

    def test_source_runtime_is_explicitly_non_release(self):
        documentation = (ROOT / "docs" / "IVINS_DEV.md").read_text(encoding="utf-8")
        self.assertIn("-IvinsRuntime source", documentation)
        self.assertIn("cannot serve as official", documentation)

    def test_doctor_never_accepts_parent_head_for_empty_submodule(self):
        command = (ROOT / "scripts" / "dev-command.ps1").read_text(encoding="utf-8")
        helper = command.split("function Get-ExactGitHead", 1)[1].split(
            "function Invoke-Doctor", 1
        )[0]
        doctor = command.split("function Invoke-Doctor", 1)[1].split(
            "function Invoke-Setup", 1
        )[0]
        self.assertIn("Test-Path -LiteralPath (Join-Path $Path '.git')", helper)
        self.assertIn("rev-parse --show-toplevel", helper)
        self.assertIn("$actualTop -ine $expectedTop", helper)
        self.assertIn("Get-ExactGitHead $path", doctor)
        self.assertIn("not initialized as an exact submodule checkout", doctor)

    def test_wsl_bootstrap_is_normalized_to_lf_before_bash(self):
        setup = (ROOT / "scripts" / "setup-wsl-distro.ps1").read_text(encoding="utf-8")
        self.assertIn('$bootstrap.Replace("`r`n", "`n").Replace("`r", "`n")', setup)
        self.assertIn("bash -lc $bootstrapLf", setup)
        self.assertNotIn("bash -lc $bootstrap\n", setup)

        common = (ROOT / "scripts" / "common.ps1").read_text(encoding="utf-8")
        invoke_wsl = common.split("function Invoke-Wsl", 1)[1].split(
            "function Convert-ToWslPath", 1
        )[0]
        self.assertIn('$Command.Replace("`r`n", "`n").Replace("`r", "`n")', invoke_wsl)
        self.assertIn("bash -lc $commandLf", invoke_wsl)

    def test_builtin_environment_does_not_require_a_submodule_property(self):
        common = (ROOT / "scripts" / "common.ps1").read_text(encoding="utf-8")
        initializer = common.split("function Initialize-EnvironmentPackage", 1)[1].split(
            "function Resolve-EnvironmentPackageFile", 1
        )[0]
        self.assertIn("psobject.Properties['submodule']", initializer)
        self.assertIn("if (-not $submoduleProperty", initializer)
        self.assertNotIn("-not $property.Value.submodule", initializer)

    def test_firewall_permission_errors_cannot_be_reported_as_pass(self):
        firewall = (ROOT / "scripts" / "configure-firewall.ps1").read_text(
            encoding="utf-8"
        )
        for command in (
            "Set-NetFirewallRule",
            "Set-NetFirewallApplicationFilter",
            "Set-NetFirewallPortFilter",
            "New-NetFirewallRule",
            "Set-NetFirewallHyperVRule",
            "New-NetFirewallHyperVRule",
        ):
            line = next(line for line in firewall.splitlines() if command in line)
            self.assertIn("-ErrorAction Stop", line)


if __name__ == "__main__":
    unittest.main()
