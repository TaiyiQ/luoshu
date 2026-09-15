# Storage return examples

These examples use a compact five-column storage grid to exercise storage-row selection.


| Circuit | Returning groups | Expected result |
| --- | --- | --- |
| `bottom-row.qasm` | 1 AOD, then 1 fixed | Both groups return to the bottom row. |
| `exact-fit.qasm` | 1 AOD, then 4 fixed | The second group exactly fills the four remaining bottom-row sites. |
| `next-row.qasm` | 3 AOD, then 3 fixed | The second group skips the bottom row, which has only two free sites, and returns to the row above. |
| `no-available-row.qasm` | 1 AOD, then 6 fixed | The six-atom group fits in no five-site row, so compilation returns `error.StorageRowFull`. |
