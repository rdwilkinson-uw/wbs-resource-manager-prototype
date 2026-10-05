# Resource Manager — Test Plan and Results

**System under test:** Resource Manager prototype (single-page web app), sample data and imported data
**Date of run:** 2 October 2026 · **Browser:** Chromium (automated, Playwright)
**Overall result:** all methods pass, after the fixes listed below. One near-miss is noted (Performance).

---

## 1. Why several methods

Each kind of test finds a different kind of problem. Feature tests confirm things work as designed; the
other methods look for problems nobody thought to write a test for.

| # | Method | What it finds | Pass criterion |
|---|---|---|---|
| 1 | **Functional regression** | Features that stop working after a change | Every feature test passes |
| 2 | **Permission matrix** | A role able to change something it shouldn't, even by bypassing the screens | Data unchanged for every disallowed role and action |
| 3 | **Script injection (XSS)** | Text that the page mistakenly runs as code | Planted code never runs on any screen, role, dropdown, dialog, CIS page or export |
| 4 | **Monkey testing** | Crashes from unexpected sequences of clicks and input | No page errors across thousands of random actions |
| 5 | **Data integrity rules** | Silent damage that looks fine on screen | Internal rules hold after random use (see 3.5) |
| 6 | **Accessibility** | Barriers for keyboard and screen-reader users | Every control named; one main heading; unique ids; Tab never traps; focus always visible; contrast AA |
| 7 | **Responsive layout** | Pages that scroll sideways on phones/tablets | No sideways scrolling at 390 px and 768 px |
| 8 | **Performance at scale** | Screens that become slow with real volumes | Screens drawn under 300 ms; edits under 300 ms |
| 9 | **Import robustness** | Crashes from broken or unexpected files | A clear message every time; page still usable |

---

## 2. Results summary

| Method | Checks | Result |
|---|---|---|
| Functional regression | ~45 feature test scripts | **Pass** |
| Permission matrix | 157 | **Pass** (after fix) |
| Script injection | 5 (29 screen/role combinations) | **Pass** |
| Monkey testing | 6 runs × 4 roles × 150 actions = **3,600 actions** | **Pass** |
| Data integrity | after every 25 random actions | **Pass** |
| Accessibility | 65 + contrast in light and dark | **Pass** (after test corrections) |
| Responsive layout | 62 | **Pass** (after fix) |
| Performance at scale | 17 | **Pass**, one near-miss noted |
| Import robustness | 9 broken files | **Pass** |

---

## 3. Findings and fixes

### 3.1 Permissions — **10 unprotected Owner actions (fixed)**
The permission matrix showed that changing an occurrence's number of groups, linking/unlinking a course, and
deleting one or all occurrences could be triggered by a Head, PAS Admin or member of staff by bypassing the
screen. An audit of every Owner-only action then found the same omission in **moving staff between groups, saving
or deleting a module, adding an occurrence, and creating, saving or deleting a course** — ten in all. Each was
hidden on screen but had no role check. All now refuse anyone but the Owner; the matrix re-run shows 157/157.

> For the PHP build, this confirms the rule: **every** server action checks the role itself.

### 3.2 Responsive layout — **top bar pushed every page sideways on phones and tablets (fixed)**
Every screen scrolled sideways by the same amount for a given person (96 px for the Owner on a phone). Cause:
the logo area reserved 250 px at all sizes and the top bar could not wrap, so the light/dark and account buttons
were off-screen. The top bar now wraps onto two lines when needed. 62/62 checks pass.

### 3.3 Performance at scale — **three slow screens (fixed); one near-miss**
Tested with 404 modules, 805 occurrences, 168 staff, 4,010 sessions (602 KB of data).

| Screen | Before | After | Fix |
|---|---|---|---|
| Module leaders | 1,174 ms | ~110 ms | Staff dropdowns fill their list when opened (was ~46,000 options up front) |
| Reports | 846 ms | ~270 ms | Each person's totals worked out once per screen draw and reused |
| Overview | 2,131 ms | ~250–470 ms | Shows the first 50 issues with *Show all* and counts by type |

**Near-miss:** the Overview's worst case (deliberately extreme test data producing **15,915 issues**) draws in
about 0.25–0.5 seconds. Real data should produce far fewer issues. Re-time this on the real server with real data.

All other screens draw in under 170 ms; an allocation edit takes ~35 ms; publishing everyone plus the Course
Information Site takes ~0.35 s.

### 3.4 Also fixed during this cycle
- **Dialog buttons off-screen:** tall dialogs (e.g. Semester dates) scrolled as a whole, hiding Save/Cancel.
  Now only the middle scrolls; title, error message and buttons always visible.
- **Staff ID removed from Staff details › Totals** (by request); rows remain in staff ID order.

### 3.5 Data integrity rules checked
Every allocation, session and role holder refers to something that exists · every occurrence has a budget for
every time slot · no negative budgets or credits · sessions are on a weekday and end after they start · every
person is in a group that exists · each person's total equals the sum of their allocations and roles · the year
list is the created years plus exactly one next year · any unsaved-changes restore point is valid.

### 3.6 Not problems (test corrections)
Some first-run failures were in the tests themselves, investigated before changing anything: e.g. the keyboard
test mistook identical-looking neighbouring buttons for "stuck" focus; the sign-in screen's heading sits outside
the main area the test first searched. These were corrected and confirmed as non-issues.

---

## 4. What automated testing here cannot cover

| Area | Why | Recommended action |
|---|---|---|
| **Other browsers** (Edge, Firefox, Safari, mobile Safari) | Only Chromium is available here | Manual check of the main tasks in each (checklist below) |
| **The PHP server code** | No PHP/MariaDB in this environment | Health check on the server; then the checklist below on staging |
| **Screen readers** (NVDA, JAWS, VoiceOver) | Automated checks confirm names and structure, not the full listening experience | 30-minute walkthrough with NVDA on Windows |
| **Real data volumes and edge cases** | Synthetic data only | Import a copy of the real database on staging; re-run performance |
| **Usability** | Tests can't judge whether something is clear | User acceptance testing with one Head, one PAS Admin and two staff |

## 5. Manual checklist for staging (per browser)
1. Sign in with an activation link; set a password; sign out and in again.
2. Owner: create a module, allocate staff, add sessions, publish a department.
3. Head: allocate on a module; add a person to a non-teaching role; try the Allocate button from a timetable.
4. PAS Admin: edit sessions by typing and pasting days/times; confirm other screens are read-only.
5. Staff: view own timetable (By module, By time, Chart); export to Outlook and import the file; open the
   Course Information Site and drill into a module.
6. Switch to Dark mode, sign out and back in: Dark is remembered.
7. On a phone: open each screen; nothing scrolls sideways; buttons reachable.
8. Try to open an Owner-only address while signed in as Head: refused.

## 6. Re-running
The automated suite is kept with the project and is re-run after every change: the functional regression
scripts plus `perm`, `xss`, `monkey` (any seed), `a11y`, `responsive`, `perf` and `importrob`, with a colour
contrast audit in light and dark mode. Monkey testing uses repeatable seeds, so any failure can be reproduced exactly.
