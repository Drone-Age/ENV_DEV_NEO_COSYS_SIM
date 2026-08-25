from vins_sim_bringup.imu_qos_adapter import MonotonicImuGate


def test_monotonic_gate_rejects_duplicates_and_regressions():
    gate = MonotonicImuGate()
    assert gate.accept(100)
    assert not gate.accept(100)
    assert not gate.accept(99)
    assert gate.accept(101)
    assert gate.published == 2
    assert gate.rejected_duplicate == 1
    assert gate.rejected_regressive == 1
