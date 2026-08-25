from glob import glob
from setuptools import find_packages, setup


package_name = "vins_sim_bringup"

setup(
    name=package_name,
    version="2.0.0",
    packages=find_packages(exclude=("test",)),
    data_files=[
        ("share/ament_index/resource_index/packages", ["resource/" + package_name]),
        ("share/" + package_name, ["package.xml"]),
        ("share/" + package_name + "/launch", glob("launch/*.launch.py")),
        ("share/" + package_name + "/config", glob("config/*.yaml")),
    ],
    install_requires=["setuptools"],
    zip_safe=True,
    maintainer="Drone Age",
    maintainer_email="dev@drone-age.com",
    description="Cosys/Unreal VINS, iHUB and ExternalNav integration",
    license="MIT",
    entry_points={
        "console_scripts": [
            "imu_qos_adapter = vins_sim_bringup.imu_qos_adapter:main",
        ]
    },
)
