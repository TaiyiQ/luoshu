# gate-compiler vs NALAC Table I (20 qubits)

| circuit        | CZ paper | CZ ours | ∥ paper | ∥ ours | route ms NALAC |         route ms ours |
| :------------- | -------: | ------: | ------: | -----: | -------------: | --------------------: |
| ae             |      380 |     434 |     1.1 |   3.31 |             32 |                 109.8 |
| dj             |       19 |      19 |     1.0 |   1.00 |              1 |                   4.6 |
| ghz            |       19 |      19 |     1.0 |   1.00 |              7 |                  17.1 |
| graphstate     |       20 |      20 |     3.3 |   3.33 |              1 |                   4.3 |
| qft            |      408 |     410 |     1.0 |   5.33 |             22 |                  66.4 |
| qftentangled   |      429 |     429 |     2.8 |   5.43 |             31 |                  70.4 |
| qnn            |      778 |      19 |     3.6 |   1.00 |             57 |                  17.1 |
| qpeexact       |      406 |     407 |     3.7 |   3.67 |             43 |                  93.3 |
| qpeinexact     |      407 |     407 |     3.7 |   3.63 |             43 |                  93.7 |
| realamprandom  |      570 |      57 |     1.2 |   2.48 |             27 |                  21.8 |
| su2random      |      570 |      57 |     1.2 |   2.48 |             27 |                  21.8 |
| twolocalrandom |      570 |       — |     1.2 |      — |             27 | _error: SiteConflict_ |
| wstate         |       38 |      38 |     1.0 |   1.31 |              7 |                  26.0 |
