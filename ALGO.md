# Monotonic Stack

A stack where elements are always kept in sorted order (either always increasing or always decreasing from bottom to top).

When you push a new element, you first **pop everything that violates the order**. Those popped elements are the ones for which the new element is the "nearest neighbor with property."

---

## Concrete example — LC 739 (Daily Temperatures)

```
temps = [73, 74, 75, 71, 69, 72, 76, 73]
```

Find for each day: how many days until a warmer day?

Process left to right, stack holds **indices of unresolved days** (temperatures are decreasing from bottom to top — monotonic decreasing):

```
i=0  push 0          stack: [0]          (73)
i=1  74 > 73 → pop 0, answer[0]=1-0=1   stack: [1]          (74)
i=2  75 > 74 → pop 1, answer[1]=2-1=1   stack: [2]          (75)
i=3  71 < 75 → push   stack: [2,3]       (75,71)
i=4  69 < 71 → push   stack: [2,3,4]     (75,71,69)
i=5  72 > 69 → pop 4, answer[4]=5-4=1
     72 > 71 → pop 3, answer[3]=5-3=2
     72 < 75 → push   stack: [2,5]       (75,72)
i=6  76 > 72 → pop 5, answer[5]=6-5=1
     76 > 75 → pop 2, answer[2]=6-2=4
               push   stack: [6]          (76)
i=7  73 < 76 → push   stack: [6,7]       (76,73)
```

Each element is pushed once and popped once → **O(N) total**.

---

## Why popping = "found your answer"

When element `i` gets popped by element `j`, it means `j` is the **first element to the right of `i` that broke the stack's order** — i.e., the nearest neighbor with the property you care about. That's the insight the whole pattern rests on.

---

## Applied to Phase 2 of computeRestingPositions

### The elements

| LC 739 | Phase 2 |
|---|---|
| `temps` array | `aod.nodes.items` array |
| Index `i` = a day | Index `i` = an AOD node |
| `temps[i]` = the temperature | `active.contains(aod.nodes.items[i])` = is this AOD active? |

### The query

LC 739: for each day `i`, find the smallest `j > i` where `temps[j] > temps[i]`.

Phase 2: for each **resting** AOD at index `i`, find:
- Smallest `j > i` where AOD `j` is active → nearest active right neighbor
- Largest `j < i` where AOD `j` is active → nearest active left neighbor

LC 739 answers **half** of Phase 2's query — the right neighbor only.

### Stack mechanics side by side

**LC 739** — stack holds indices of days waiting for their answer:

```
encounter day j:
  while stack not empty AND temps[j] > temps[stack.top]:
    i = stack.pop()
    answer[i] = j - i        // j is i's nearest warmer day
  push j
```

**Phase 2 right neighbor** — stack holds indices of resting AODs waiting for their right neighbor:

```
encounter AOD at index j:
  if active:
    while stack not empty:
      i = stack.pop()
      right_neighbor[i] = j  // j is i's nearest active right neighbor
  else:
    push j                   // resting, unresolved
```

The predicate changes (`temps[j] > temps[i]` → `active(j)`), but the stack logic is identical: an active AOD resolves all resting AODs on the stack, exactly as a warmer day resolves all cooler days below it.

### The left neighbor — what LC 739 doesn't need

No stack required. As you scan left to right, track the last active AOD seen:

```
last_active = null
for j in 0..n:
  if active(aod[j]):
    last_active = j
  else:
    left_neighbor[j] = last_active  // most recent active to the left
```

Phase 2 in full = **LC 739's stack** (right neighbor) + **a running variable** (left neighbor). One left-to-right pass, O(N), instead of the current O(N²) nested loop.
