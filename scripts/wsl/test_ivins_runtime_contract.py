from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def test_installed_runtime_uses_ihub_cosys_backend_without_legacy_bridge():
    launcher = (ROOT / "scripts/wsl/start_vins_stack.sh").read_text(
        encoding="utf-8"
    )
    assert 'if [[ "$runtime_mode" == source ]]; then' in launcher
    assert (
        'export IHUB_SIM_BRIDGE="$HOME/.local/share/indra-cosys/'
        'vins-overlay-jazzy/install/lib/libihub_sim_bridge.so"'
    ) in launcher
    assert '[[ -f "$IHUB_SIM_BRIDGE" ]]' in launcher
    assert "else\n    # iHUB 0.3.2 owns the Cosys RPC backend." in launcher
    assert "    unset IHUB_SIM_BRIDGE\nfi" in launcher
    assert "/opt/vio_stack/current/lib/libihub_sim_bridge.so" not in launcher


def test_newsim_launch_pins_the_cosys_camera_pitch_convention():
    launcher = (ROOT / "scripts/wsl/start_vins_stack.sh").read_text(
        encoding="utf-8"
    )
    launch = (
        ROOT / "ros_ws/src/vins_sim_bringup/launch/vins_stack.launch.py"
    ).read_text(encoding="utf-8")
    assert 'cosys_pitch_sign:="1.0"' in launcher
    assert 'DeclareLaunchArgument("cosys_pitch_sign", default_value="1.0")' in launch
    assert '"--cosys-pitch-sign", LaunchConfiguration("cosys_pitch_sign")' in launch
