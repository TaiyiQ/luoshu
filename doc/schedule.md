# Schedule

`gatecomp <circuit.qasm> --out <dir>` writes `<dir>/<name>-schedule.json`: the compiled hardware schedule as a flat list of ops. This file is the contract with the downstream pulse compiler.

## Semantics

- **Time is Logical**: `t` is a frame index, not a physical time. All ops sharing one `t` execute simultaneously; within a frame, array order applies. hysical durations are the pulse compiler's job.
- **Units**: Positions are absolute integer **nanometers**. Angles and phases are **radians**.
- **Geometry is External**: Trap grids, zone extents, and AOD limits live in the architecture TOML (`cfg/arch.toml`).
- **Zones**: `"storage"`, `"compute"`, `"readout"`, plus `"transit"` for move endpoints staged in the trap-free gaps between zones.

## Example

```jsonc
{
  "version": "0.2",
  "platform": "arch-default",
  "num_qubits": 2,
  "ops": [
    {
      "op": "raman",          // single-qubit pulse R(angle, phase) = Rz(phase) Ry(angle) Rz(-phase)
      "angle": 1.5708, "phase": 3.1416, "t": 0,
      "targets": [ { "qubit": 0, "x": 81000, "y": 27000 } ]
    },
    {
      "op": "load",           // AOD tweezer picks the atom up from its trap
      "qubit": 0,
      "x": 81000,
      "y": 27000,
      "t": 1
    },
    {
      "op": "move",           // one AOD translation: every listed atom moves
      "aod": 0,
      "translate": "y",       // "x" or "y"; each move is axis-aligned
      "from_zone": "storage",
      "to_zone": "transit",
      "t": 2,
      "atoms": [
        {
          "qubit": 0,
          "from": { "x": 81000, "y": 27000 },
          "to": { "x": 81000, "y": 33000 }
        }
      ]
    },
    {
      "op": "store",          // atom dropped back into an SLM trap
      "qubit": 0,
      "x": 0,
      "y": 47000,
      "t": 5
    },
    {
      "op": "rydberg",        // one global entangling pulse over the zone;
                              // atom placement determines which pairs entangle
      "zone": "compute",
      "t": 6
    },
    {
      "op": "reset",          // repump to zero-state in the named zone
      "zone": "readout",
      "t": 7,
      "qubits": [0]
    },
    {
      "op": "measure",        // readout of the listed qubits
      "zone": "readout",
      "basis": "Z",
      "t": 8,
      "qubits": [0, 1]
    }
  ]
}
```
