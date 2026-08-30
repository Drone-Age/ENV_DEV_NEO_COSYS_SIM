import json
from unittest.mock import Mock

from nav_msgs.msg import Odometry
import rclpy
from vio_stack_interfaces.msg import ExternalNavHealth, IVINSStatus

from vins_runtime_probe import VinsRuntimeProbe, apply_completion_gate


def probe_result():
    return {
        "status": "PASS",
        "gates": {"vins_tracking": True, "external_nav_ready": True},
        "measurements": {},
    }


def test_completion_gate_waits_for_mission_evidence(tmp_path):
    result = apply_completion_gate(probe_result(), tmp_path / "mission.json")
    assert result["status"] == "WAITING"
    assert result["gates"]["mission_complete"] is False


def test_completion_gate_accepts_only_pass_verdict(tmp_path):
    path = tmp_path / "mission.json"
    path.write_text(json.dumps({"verdict": "PASS"}), encoding="utf-8")
    result = apply_completion_gate(probe_result(), path)
    assert result["status"] == "PASS"
    assert result["gates"]["mission_complete"] is True
    assert result["measurements"]["mission_verdict"] == "PASS"


def test_ground_truth_gate_rejects_accumulated_external_nav_drift():
    rclpy.init()
    node = VinsRuntimeProbe()
    try:
        truth = Odometry()
        truth.pose.pose.position.x = 10.0
        node._ground_truth(truth)
        aligned = Odometry()
        aligned.pose.pose.position.x = 11.0
        for _ in range(5):
            node._mavros_odometry(aligned)
        assert node.result()["gates"]["external_nav_ground_truth"] is True

        drifted = Odometry()
        drifted.pose.pose.position.x = 16.0
        node._mavros_odometry(drifted)
        result = node.result()
        assert result["gates"]["external_nav_ground_truth"] is False
        assert result["measurements"][
            "external_nav_maximum_ground_truth_error_m"
        ] == 6.0
    finally:
        node.destroy_node()
        rclpy.shutdown()


def test_alignment_capture_waits_for_qualified_vins_and_admits_only_ready_external_nav():
    rclpy.init()
    node = VinsRuntimeProbe()
    try:
        node.enable_publisher = Mock()
        node.admission_publisher = Mock()
        node._request_alignment()
        node.enable_publisher.publish.assert_not_called()
        node.admission_publisher.publish.assert_not_called()

        initialization = IVINSStatus()
        initialization.state = IVINSStatus.READY
        initialization.allow_navigation_output = True
        node.initialization = initialization
        node._request_alignment()
        node.enable_publisher.publish.assert_called_once()
        node.admission_publisher.publish.assert_not_called()

        health = ExternalNavHealth()
        health.state = ExternalNavHealth.READY
        health.ready = True
        health.alignment_valid = True
        node.external_nav = health
        node._request_alignment()
        assert node.enable_publisher.publish.call_count == 2
        node.admission_publisher.publish.assert_called_once()
    finally:
        node.destroy_node()
        rclpy.shutdown()
