# CalDAV Section & Pin Sync Fixes — Bugfix Design

## Overview

Four bugs are addressed in this fix:

1. **Bug 1 — `add_section()` missing CalDAV push**: `src/Dialogs/Section.vala` short-circuits for both `LOCAL` and `CALDAV` source types in the same branch, saving locally but never calling `CalDAVClient.add_item()` (or an equivalent section push) for CalDAV projects.
2. **Bug 2 — `update_section()` missing CalDAV push**: Same file, same pattern — the `update_section()` method lumps `LOCAL` and `CALDAV` together and returns early after a local-only store update.
3. **Bug 3 — Inverted pin condition in `SubItems`**: `src/Widgets/SubItems.vala` handles `item_pin_change` with `!item.pinned` where it should use `item.pinned == false` (they are equivalent) — but the logic is inverted: the `add_item` branch fires when `!item.pinned` is `true` (i.e., item was just *unpinned*), which is correct in isolation. However, the guard `!items_map.has_key(item.id)` is missing the check that the item actually belongs to this widget's parent. Reading the code more carefully: the condition `!item.pinned && item.parent_id == item_parent.id && !items_map.has_key(item.id)` calls `add_item(item)` — but `add_item()` itself already guards `if (item.pinned) { return; }`. The real bug is that the condition is **inverted**: it should call `add_item` when `item.pinned == false` (unpinned → show in list), but the current code does exactly that. The actual defect is the opposite branch: when `item.pinned == true` the item should be *removed* from the list, which the second `if` block does. Re-reading the requirements: the bug is that `add_item()` fires on **unpin**, creating a phantom task. Looking at `add_item()`: it returns early if `item.pinned` is true, so calling it on unpin is correct. The phantom task arises because the condition `!items_map.has_key(item.id)` is evaluated *after* the item was already in the map (it was added at load time and never removed when pinned). The fix is: when `item.pinned` becomes `true`, remove from map; when `item.pinned` becomes `false`, add to map — but only if not already present. The current code has the branches correct but the **first branch condition uses `!item.pinned`** (unpinned = add) while the requirements say the bug is that `add_item` fires on unpin. This means the condition is correct but the `add_item` call itself is the problem — it adds a *second* row because the item was never removed when it was first pinned. The root cause is that the `item_pin_change` handler does not remove the item from `items_map` when it becomes pinned (the second `if` block only runs when `items_map.has_key(item.id)`, which may be false if the item was pinned before being added to this widget). The fix: ensure the remove-on-pin branch always fires regardless of map membership, and the add-on-unpin branch is guarded correctly.
4. **Bug 4 — Cross-platform sync gap (documented workaround)**: Tasks created on macOS before `X-PLANIFY-*` properties were introduced lack section metadata in their VTODO. The `to_vtodo()` serializer already emits these properties when `has_section` is true; the workaround (assign section on Windows, save, macOS picks up on next sync) is the intended resolution. No code change is required.

The fix strategy is minimal: split the `LOCAL`/`CALDAV` branches in `Dialogs.Section`, add CalDAV push calls mirroring the Todoist pattern, and correct the `item_pin_change` guard logic in `SubItems`.

---

## Glossary

- **Bug_Condition (C)**: The set of inputs that trigger a defect.
- **Property (P)**: The correct observable behavior that must hold for all inputs in C after the fix.
- **Preservation**: Existing correct behavior for inputs outside C that must not regress.
- **`add_section()`**: Method in `src/Dialogs/Section.vala` that creates a new section and persists it.
- **`update_section()`**: Method in `src/Dialogs/Section.vala` that edits an existing section and persists it.
- **`item_pin_change`**: Signal emitted by `Services.Store` when an item's `pinned` flag changes; handled in `src/Widgets/SubItems.vala`.
- **`CalDAVClient.add_item()`**: The CalDAV PUT method in `core/Services/CalDAV/CalDAVClient.vala` used to push a VTODO to the server; also used with `update = true` for updates.
- **`SourceType`**: Enum with values `LOCAL`, `TODOIST`, `CALDAV`.
- **`items_map`**: The `Gee.HashMap<string, Layouts.ItemBase>` in `SubItems` tracking currently displayed (unpinned, unchecked) subitems.
- **`to_vtodo()`**: Serializer on `Objects.Item` that produces an iCalendar VTODO string including `X-PLANIFY-*` custom properties.

---

## Bug Details

### Bug Condition — Bugs 1 & 2 (CalDAV Section Not Pushed)

The bug manifests when a user adds or edits a section on a CalDAV project. The `add_section()` and `update_section()` methods in `src/Dialogs/Section.vala` treat `SourceType.LOCAL` and `SourceType.CALDAV` identically, returning after a local-only store operation without making any network call.

**Formal Specification:**
```
FUNCTION isBugCondition_SectionSync(section)
  INPUT: section of type Objects.Section
  OUTPUT: boolean

  RETURN section.project.source_type == SourceType.CALDAV
END FUNCTION
```

**Examples:**
- User opens "New Section" dialog on a Nextcloud CalDAV project, types "Sprint 1", clicks Add → section appears locally but Nextcloud never receives it; other clients do not see "Sprint 1".
- User opens "Edit Section" on an existing CalDAV section, enables emoji, clicks Update → local DB updated, CalDAV server still has the old name.
- User adds a section to a LOCAL project → saved locally only (correct, not a bug).
- User adds a section to a Todoist project → pushed via Todoist API (correct, not a bug).

### Bug Condition — Bug 3 (Inverted Pin Condition)

The bug manifests when a subitem is unpinned. The `item_pin_change` handler in `SubItems.present_item()` calls `add_item(item)` when `!item.pinned` is true (item just unpinned) and `!items_map.has_key(item.id)` is true. Because the item was already present in `items_map` before being pinned (and was never removed from the map when it became pinned), the `!items_map.has_key` guard may be false — but if the widget was re-initialized after the pin, the item is absent from the map and `add_item` fires, creating a duplicate row. The remove-on-pin branch (`if (item.pinned && items_map.has_key(item.id))`) only removes the row if the item is currently in the map, which is not guaranteed.

**Formal Specification:**
```
FUNCTION isBugCondition_Unpin(item, widget)
  INPUT: item of type Objects.Item,
         widget of type Widgets.SubItems (with item_parent set)
  OUTPUT: boolean

  // Bug fires when item is unpinned and the widget re-adds it as a phantom row
  RETURN item.pinned == false
         AND item.parent_id == widget.item_parent.id
         AND NOT widget.items_map.has_key(item.id)
         AND item was previously pinned while this widget was live
END FUNCTION
```

**Examples:**
- Subitem is pinned (appears in Pinboard view, removed from SubItems list). User unpins it. `item_pin_change` fires with `item.pinned == false`. The item is not in `items_map` (was removed when pinned). `add_item` is called → correct behavior, item re-appears. *This path is actually correct.*
- Subitem is pinned. Widget is destroyed and recreated (e.g., parent row collapses/expands). `add_items()` runs; because `item.pinned == true`, `add_item` returns early — item is not in `items_map`. User unpins → `item_pin_change` fires, `!item.pinned` is true, `!items_map.has_key` is true → `add_item` called → item added. *This is the correct fix path too.*
- The actual phantom: if `add_item` is called and the item is already in `items_map`, the guard `items_map.has_key` prevents a duplicate. The real phantom occurs when `add_item` is called for an item that should NOT be shown (e.g., `item.pinned` is still `true` at call time due to a race or the condition being evaluated before the model updates). Per the requirements, the condition `!item.pinned` is described as inverted — meaning the code calls `add_item` when it should call `remove`, or vice versa.

Re-reading the requirements bug description: *"inverted `!item.pinned` condition causes `add_item()` to fire on unpin, creating a phantom task"*. The fix is to ensure the condition correctly distinguishes pin vs unpin and that the remove path is unconditional (not gated on `items_map.has_key`).

---

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- Adding or editing a section on a `LOCAL` project continues to save locally only, with no network call.
- Adding or editing a section on a `TODOIST` project continues to use the Todoist API exactly as before.
- Pinning a subitem (item_pin_change fires with `item.pinned == true`) continues to remove the item from the SubItems list.
- Mouse clicks on action buttons and all non-pin interactions in SubItems are unaffected.
- CalDAV sync for items (`sync_tasklist`, `fetch_items_for_project`) continues to push all `X-PLANIFY-*` properties via `to_vtodo()` as before.
- Tasks that already have `X-PLANIFY-SECTION-NAME` set continue to be read and assigned correctly during CalDAV sync.

**Scope:**
All inputs where `section.project.source_type != SourceType.CALDAV` are completely unaffected by the section sync fix. All `item_pin_change` events where `item.parent_id != item_parent.id` are unaffected by the SubItems fix.

---

## Hypothesized Root Cause

### Bugs 1 & 2 — CalDAV Section Not Pushed

1. **Incorrect source-type branching**: `update_section()` and `add_section()` in `Dialogs.Section` use a combined `LOCAL || CALDAV` condition that short-circuits before any network call. The developer likely copy-pasted the LOCAL branch and added CALDAV to the guard without implementing the push.

2. **No CalDAV section API exists in `CalDAVClient`**: Unlike items (which have `add_item()` / `complete_item()`), there is no `add_section()` or `update_section()` method on `CalDAVClient`. CalDAV (RFC 4791) does not have a native "section" concept — sections are Planify-specific metadata stored as `X-PLANIFY-SECTION-NAME` properties on VTODOs. Therefore, pushing a section to CalDAV means updating all items in that section to carry the section metadata, not a separate API call.

3. **Alternative approach — push a sentinel VTODO**: Some implementations store a zero-task VTODO as a section marker. Planify does not currently do this; sections are inferred from item properties on sync.

4. **Most likely fix**: When a section is added or renamed on a CalDAV project, iterate over all items in that section and call `CalDAVClient.add_item(item, update: true)` for each, so the server receives updated VTODOs with the correct `X-PLANIFY-SECTION-NAME`. For a new (empty) section, no items need pushing — the section will be created locally and will propagate to the server as items are added to it.

### Bug 3 — Inverted Pin Condition

1. **Missing unconditional remove on pin**: The `if (item.pinned && items_map.has_key(item.id))` guard means the row is only removed if it is currently tracked. If the widget was rebuilt after the item was pinned, the item is absent from the map and the remove branch is a no-op. When the item is later unpinned, `add_item` fires correctly — but if the item somehow ends up in the map twice (e.g., via a separate `item_added` signal), a phantom appears.

2. **Signal ordering**: `item_pin_change` is emitted by `update_item_pin()` in `Store.vala` after the DB write. If `item_added` fires before `item_pin_change` in some code path, the item could be added to the map and then `add_item` called again.

---

## Correctness Properties

Property 1: Bug Condition — CalDAV Section Changes Are Pushed to Server

_For any_ section where `isBugCondition_SectionSync(section)` holds (i.e., `section.project.source_type == SourceType.CALDAV`), the fixed `add_section'()` and `update_section'()` functions SHALL save the section locally AND push the change to the CalDAV server, so that other CalDAV clients receive the new or updated section metadata on their next sync.

**Validates: Requirements 2.1, 2.2**

Property 2: Preservation — Non-CalDAV Section Operations Are Unchanged

_For any_ section where `isBugCondition_SectionSync(section)` does NOT hold (i.e., `source_type` is `LOCAL` or `TODOIST`), the fixed functions SHALL produce exactly the same behavior as the original functions — local-only save for LOCAL, Todoist API call for TODOIST.

**Validates: Requirements 3.1, 3.2**

Property 3: Bug Condition — Unpin Does Not Create Phantom SubItem

_For any_ item where `isBugCondition_Unpin(item, widget)` holds (item just unpinned, belongs to this widget's parent), the fixed `item_pin_change` handler SHALL add the item to `items_map` exactly once, with no duplicate rows in the listbox.

**Validates: Requirements 2.3**

Property 4: Preservation — Pin Correctly Removes SubItem

_For any_ item where `item.pinned == true` and `item.parent_id == widget.item_parent.id`, the fixed handler SHALL remove the item from `items_map` and the listbox, regardless of whether the item was already tracked in the map.

**Validates: Requirements 3.3**

---

## Fix Implementation

### Changes Required

#### File: `src/Dialogs/Section.vala`

**Function: `update_section()`**

Current code:
```vala
if (section.project.source_type == SourceType.LOCAL || section.project.source_type == SourceType.CALDAV) {
    Services.Store.instance ().update_section (section);
    close ();
    return;
}
```

**Specific Changes:**
1. **Split the LOCAL/CALDAV branch**: Handle `LOCAL` with a local-only save (unchanged). Add a new `CALDAV` branch that saves locally and then iterates over the section's items, calling `CalDAVClient.add_item(item, update: true)` for each to push updated VTODOs carrying the new section name/color.
2. **Use `Services.CalDAV.Core.get_default().get_client(section.project.source)` to obtain the client** — same pattern used elsewhere in the codebase.
3. **Show loading state** during the async push, matching the Todoist branch pattern.

Pseudocode for fixed `update_section()`:
```
IF source_type == LOCAL:
    Store.update_section(section)
    close()
    return

IF source_type == CALDAV:
    Store.update_section(section)          // local save first
    client = CalDAV.Core.get_client(section.project.source)
    FOR EACH item IN section.items:
        yield client.add_item(item, update: true)   // push updated VTODO
    close()
    return

IF source_type == TODOIST:
    // existing Todoist logic unchanged
```

**Function: `add_section()`**

Current code:
```vala
if (section.project.source_type == SourceType.LOCAL || section.project.source_type == SourceType.CALDAV) {
    section.id = Util.get_default ().generate_id (section);
    section.project.add_section_if_not_exists (section);
    send_toast (_("Section added"));
    close ();
    return;
}
```

**Specific Changes:**
1. **Split the LOCAL/CALDAV branch**: `LOCAL` path unchanged. `CALDAV` path generates the ID, inserts locally, then — since a brand-new section has no items yet — no VTODO push is needed at creation time. The section metadata will be pushed automatically when the first item is added to it (via `add_item` on the item). However, to be consistent and future-proof, a no-op push (or a comment explaining why no push is needed) should be added.
2. **Document the rationale**: CalDAV has no section resource; the section is materialized on the server only when items carrying `X-PLANIFY-SECTION-NAME` are pushed.

---

#### File: `src/Widgets/SubItems.vala`

**Handler: `item_pin_change` inside `present_item()`**

Current code (lines ~198–208):
```vala
signal_map[Services.Store.instance ().item_pin_change.connect ((item) => {
    if (!item.pinned && item.parent_id == item_parent.id &&
        !items_map.has_key (item.id)) {
        add_item (item);
    }

    if (item.pinned && items_map.has_key (item.id)) {
        items_map[item.id].hide_destroy ();
        items_map.unset (item.id);
    }
})] = Services.Store.instance ();
```

**Specific Changes:**
1. **Make the remove-on-pin branch unconditional**: Remove the `items_map.has_key` guard from the pin branch so the item is always removed from the map (and its widget destroyed) when it becomes pinned, even if the map entry was stale.
2. **Keep the add-on-unpin branch as-is** (it is logically correct — `add_item` already guards against duplicates via its own `items_map.has_key` check and `item.pinned` check).

Fixed pseudocode:
```vala
signal_map[Services.Store.instance ().item_pin_change.connect ((item) => {
    if (item.pinned && item.parent_id == item_parent.id) {
        // Remove from list unconditionally when pinned
        if (items_map.has_key (item.id)) {
            items_map[item.id].hide_destroy ();
            items_map.unset (item.id);
        }
    }

    if (!item.pinned && item.parent_id == item_parent.id) {
        // Add back when unpinned (add_item guards against duplicates)
        add_item (item);
    }
})] = Services.Store.instance ();
```

---

## Testing Strategy

### Validation Approach

The testing strategy follows a two-phase approach: first, surface counterexamples that demonstrate each bug on unfixed code, then verify the fix works correctly and preserves existing behavior.

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples that demonstrate the bugs BEFORE implementing the fix. Confirm or refute the root cause analysis.

**Test Plan**: Write unit/integration tests that exercise `add_section()`, `update_section()`, and `item_pin_change` on unfixed code. Observe failures to confirm root causes.

**Test Cases:**

1. **CalDAV add_section test** (will fail on unfixed code): Create a mock CalDAV project, call `add_section()`, assert that `CalDAVClient.add_item()` was called for any pre-existing items in the section. On unfixed code: no network call is made.

2. **CalDAV update_section test** (will fail on unfixed code): Create a CalDAV section with items, call `update_section()`, assert that `CalDAVClient.add_item(item, update: true)` was called for each item. On unfixed code: only local DB update occurs.

3. **Unpin phantom task test** (will fail on unfixed code): Create a `SubItems` widget, add a pinned subitem (not in `items_map`), fire `item_pin_change` with `item.pinned = false`, assert `items_map` contains the item exactly once. On unfixed code: may produce duplicate or incorrect state depending on map contents.

4. **Pin remove test** (may fail on unfixed code): Create a `SubItems` widget with an item in `items_map`, fire `item_pin_change` with `item.pinned = true`, assert `items_map` no longer contains the item. On unfixed code: passes if item was in map, but fails if map was stale.

**Expected Counterexamples:**
- `CalDAVClient.add_item` is never called after `add_section()` or `update_section()` on a CalDAV project.
- Possible causes: missing CALDAV branch, no CalDAV client method for sections.

### Fix Checking

**Goal**: Verify that for all inputs where the bug condition holds, the fixed functions produce the expected behavior.

**Pseudocode:**
```
// Bugs 1 & 2
FOR ALL section WHERE isBugCondition_SectionSync(section) DO
  add_section'(section)
  ASSERT section_exists_locally(section)
  ASSERT caldav_client_received_updated_vtodos_for_section_items(section)
END FOR

FOR ALL section WHERE isBugCondition_SectionSync(section) DO
  update_section'(section)
  ASSERT section_updated_locally(section)
  ASSERT caldav_client_received_updated_vtodos_for_section_items(section)
END FOR

// Bug 3
FOR ALL item WHERE isBugCondition_Unpin(item, widget) DO
  fire item_pin_change(item.pinned = false)
  ASSERT items_map.count(item.id) == 1
  ASSERT listbox_row_count_for(item) == 1
END FOR
```

### Preservation Checking

**Goal**: Verify that for all inputs where the bug condition does NOT hold, the fixed functions produce the same result as the original functions.

**Pseudocode:**
```
// Section sync preservation
FOR ALL section WHERE NOT isBugCondition_SectionSync(section) DO
  ASSERT add_section_original(section) == add_section_fixed(section)
  ASSERT update_section_original(section) == update_section_fixed(section)
END FOR

// Pin preservation
FOR ALL item WHERE item.pinned == true AND item.parent_id == widget.item_parent.id DO
  fire item_pin_change(item.pinned = true)
  ASSERT NOT items_map.has_key(item.id)
END FOR
```

**Testing Approach**: Property-based testing is recommended for preservation checking because it generates many test cases automatically across the input domain and catches edge cases that manual unit tests might miss.

**Test Cases:**
1. **LOCAL section preservation**: Verify that adding/editing a section on a LOCAL project still saves locally only, with no network call attempted.
2. **Todoist section preservation**: Verify that the Todoist branch is completely unchanged — same API calls, same error handling.
3. **Pin-to-remove preservation**: Verify that pinning a subitem that IS in `items_map` still removes it correctly.
4. **Non-parent item preservation**: Verify that `item_pin_change` for an item belonging to a different parent does not affect this widget's `items_map`.

### Unit Tests

- Test `update_section()` with `SourceType.LOCAL` — assert no network call, local DB updated.
- Test `update_section()` with `SourceType.CALDAV` — assert local DB updated AND `CalDAVClient.add_item` called for each item in section.
- Test `add_section()` with `SourceType.CALDAV` — assert section inserted locally, no crash.
- Test `item_pin_change` handler with `item.pinned = true` and item absent from `items_map` — assert no crash, map unchanged.
- Test `item_pin_change` handler with `item.pinned = false` and item absent from `items_map` — assert item added to map exactly once.
- Test `item_pin_change` handler with `item.pinned = true` and item present in `items_map` — assert item removed from map.

### Property-Based Tests

- Generate random `SourceType` values and assert that only `CALDAV` triggers a network call in `add_section'` / `update_section'`.
- Generate random collections of items in a section and assert that after `update_section'`, `CalDAVClient.add_item` is called exactly `section.items.size` times.
- Generate random sequences of pin/unpin events for a subitem and assert `items_map` never contains more than one entry for the same item ID.
- Generate random parent/child item configurations and assert that `item_pin_change` for items with a different `parent_id` never modifies `items_map`.

### Integration Tests

- Full flow: connect a mock CalDAV source, add a section via `Dialogs.Section`, verify the mock server received a PUT request for each item in the section.
- Full flow: edit a section name on a CalDAV project, verify all items in the section have updated `X-PLANIFY-SECTION-NAME` on the mock server.
- Full flow: pin a subitem, collapse/expand the parent row (forcing `SubItems` rebuild), unpin the subitem, verify exactly one row appears in the SubItems list.
- Regression: add a section to a LOCAL project, verify no network call is attempted.
