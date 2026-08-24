# Canonical demo route

`scripts/wsl/demo_mission.py` generates the route from `config/demo.json` at runtime so the geographic origin remains authoritative in one place. The sequence is TAKEOFF to 5 m, a clockwise 15 x 15 m square in local NED coordinates, return over origin, LAND and DISARM.
