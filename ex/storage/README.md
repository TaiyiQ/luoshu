# Storage return examples

These examples exercise storage-row selection.


| Circuit | Architecture | Returning group or operation | 
| --- | --- | --- | 
| `bottom-row.qasm` | `arch.toml` (3x5 storage) | 1 AOD, then 1 fixed |
| `exact-fit.qasm` | `arch.toml` (3x5 storage) | 1 AOD, then 4 fixed | 
| `next-row.qasm` | `arch.toml` (3x5 storage) | 3 AOD, then 3 fixed | 
| `multi-row.qasm` | `arch.toml` (3x5 storage) | 1 AOD, then 6 fixed | 
| `just-over-one-row.qasm` | `just-over-one-row.toml` (3x8 storage) | 1 AOD, then 9 fixed | 
| `fallback-right-edge.qasm` | `fallback-right-edge.toml` (3x6 storage) | Reset round trip of 5 selected atoms | 
| `best-fit-last-row.qasm` | `best-fit-last-row.toml` (4x6 storage) | Reset round trip of 8 selected atoms | 
| `three-row-return.qasm` | `three-row-return.toml` (4x6 storage) | Reset round trip of 13 selected atoms |
| `repeated-homecomings.qasm` | `repeated-homecomings.toml` (3x6 storage) | Sparse reset return followed by a 12-cycle CZ stage | 