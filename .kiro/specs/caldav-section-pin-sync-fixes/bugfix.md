# Bugfix Requirements Document

## Introduction

This document covers four related bugs in Planify's CalDAV integration and pin/subitem handling. Two bugs cause CalDAV sections to be silently saved only locally without being pushed to the CalDAV server (so other clients never see them). One bug causes an inverted condition in the SubItems `item_pin_change` handler that creates a phantom empty task when unpinning. The fourth is a cross-platform sync gap where tasks created on macOS before the `X-PLANIFY-*` properties were introduced lack section metadata, with a documented workaround.

## Bug Analysis

### Current Behavior (Defect)

1.1 WHEN a user adds a new section to a CalDAV project THEN the system saves the section to the local database only and does not push it to the CalDAV server, so other CalDAV clients never see the new section.

1.2 WHEN a user edits (renames or recolors) an existing section on a CalDAV project THEN the system updates the section in the local database only and does not push the change to the CalDAV server, so other CalDAV clients continue to see the old section name/color.

1.3 WHEN a user unpins a subitem (item_pin_change fires with `item.pinned == false` after the toggle) THEN the system evaluates `!item.pinned` as `true` and incorrectly calls `add_item(item)`, causing a duplicate/empty task to appear in the SubItems list.

1.4 WHEN a task was created on macOS before `X-PLANIFY-SECTION-NAME` and related properties were introduced THEN the VTODO stored in Nextcloud has no `X-PLANIFY-*` properties, so Windows Planify cannot assign the task to the correct section on sync.

### Expected Behavior (Correct)

2.1 WHEN a user adds a new section to a CalDAV project THEN the system SHALL save the section locally AND push it to the CalDAV server so that other CalDAV clients receive the new section on their next sync.

2.2 WHEN a user edits an existing section on a CalDAV project THEN the system SHALL update the section locally AND push the change to the CalDAV server so that other CalDAV clients receive the updated section name/color on their next sync.

2.3 WHEN a user unpins a subitem THEN the system SHALL evaluate the pin state correctly and SHALL NOT add the item to the SubItems list again; the item SHALL be removed from the pinned view without creating a duplicate task.

2.4 WHEN a task that was created on macOS (lacking `X-PLANIFY-*` properties) is assigned to a section on Windows and saved THEN the system SHALL push `X-PLANIFY-SECTION-NAME` (and related properties) to Nextcloud via `to_vtodo()`, so that macOS Planify reads the correct section assignment on its next sync.

### Unchanged Behavior (Regression Prevention)

3.1 WHEN a user adds or edits a section on a LOCAL project THEN the system SHALL CONTINUE TO save the section locally without attempting any network call.

3.2 WHEN a user adds or edits a section on a Todoist project THEN the system SHALL CONTINUE TO call the Todoist API and update the section as before.

3.3 WHEN a user pins a subitem (item_pin_change fires with `item.pinned == true`) THEN the system SHALL CONTINUE TO remove the item from the SubItems list correctly.

3.4 WHEN a task already has `X-PLANIFY-SECTION-NAME` set THEN the system SHALL CONTINUE TO read and assign the section correctly during CalDAV sync without modification.

3.5 WHEN a CalDAV sync runs for items THEN the system SHALL CONTINUE TO push all existing `X-PLANIFY-*` properties (pinned, section name, section color, item type, deadline) via `to_vtodo()` as before.

---

## Bug Condition Pseudocode

### Bug 1 & 2 — CalDAV Section Not Pushed to Server

```pascal
FUNCTION isBugCondition_SectionSync(project)
  INPUT: project of type Objects.Project
  OUTPUT: boolean

  RETURN project.source_type == SourceType.CALDAV
END FUNCTION

// Property: Fix Checking — Section Add
FOR ALL section WHERE isBugCondition_SectionSync(section.project) DO
  add_section'(section)
  ASSERT section_exists_locally(section) AND section_pushed_to_caldav_server(section)
END FOR

// Property: Fix Checking — Section Update
FOR ALL section WHERE isBugCondition_SectionSync(section.project) DO
  update_section'(section)
  ASSERT section_updated_locally(section) AND section_update_pushed_to_caldav_server(section)
END FOR

// Property: Preservation Checking
FOR ALL section WHERE NOT isBugCondition_SectionSync(section.project) DO
  ASSERT add_section(section) = add_section'(section)
  ASSERT update_section(section) = update_section'(section)
END FOR
```

### Bug 3 — Inverted Pin Condition in SubItems

```pascal
FUNCTION isBugCondition_Unpin(item, context)
  INPUT: item of type Objects.Item, context = SubItems widget for item.parent_id
  OUTPUT: boolean

  // Bug fires when item was just unpinned (pinned toggled to false)
  RETURN item.pinned == false AND item.parent_id == context.item_parent.id
END FUNCTION

// Property: Fix Checking — Unpin should NOT add item to SubItems
FOR ALL item WHERE isBugCondition_Unpin(item, context) DO
  result ← handle_pin_change'(item)
  ASSERT NOT item_added_to_subitems(item, context)
END FOR

// Property: Preservation Checking — Pin should still remove item from SubItems
FOR ALL item WHERE item.pinned == true AND items_map.has_key(item.id) DO
  ASSERT F(item) = F'(item)  // item is removed from SubItems list
END FOR
```
