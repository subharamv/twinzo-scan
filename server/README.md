# Twinzo Scan — server side

The device half of this system is in [`TwinzoScan/`](../TwinzoScan). This
directory holds the database schema it uploads into, and the reasoning behind the
pipeline it assumes.

- [`schema.sql`](schema.sql) — MySQL 8.0 schema. Verified by applying it to a
  clean `mysql:8.0` and running the smoke test below.
- [`smoke-test.sql`](smoke-test.sql) — walks one element from IFC import through
  a scan, registration, inspection and markup, then checks the reporting views.

```bash
docker run --rm -d --name twinzo-mysql -e MYSQL_ROOT_PASSWORD=twinzo mysql:8.0
docker exec -i twinzo-mysql mysql -uroot -ptwinzo < schema.sql
docker exec -i twinzo-mysql mysql -uroot -ptwinzo --table < smoke-test.sql
```

---

## The model pipeline

```
Revit ──IFC4 SPF──> import service ──> MySQL entity graph  ──> IFC viewer
                          │                                        ▲
                          ├──> object storage (original .ifc)      │
                          └──> tessellator ──> USDZ + elements.json │
                                                    │              │
                                              iPhone LiDAR ────────┘
                                              deviation on device
                                                    │
                                              upload ──> authoritative
                                                          recompute
```

### Why IFC4 SPF and not ifcXML

The original plan called for "IFC XML from Revit to database". ifcXML is real —
ISO 10303-28 — but Revit's native exporter targets IFC4 SPF (`.ifc`), and the XML
serialisation of the same model runs five to ten times larger for no gain
downstream. Take the SPF export.

### Why the file is not the database

Storing the `.ifc` as a blob and re-parsing it per query is the failure mode to
design out. An IFC4 model of a mid-size building is hundreds of megabytes and
tens of seconds to parse. The original file belongs in object storage as the
legal record; `elements` and `element_properties` are the queryable projection of
it, and they are what the viewer and the deviation service actually read.

`element_properties` exists because the `properties` JSON column on `elements`
answers "what are this element's properties" and cannot answer "which elements
have `Pset_WallCommon.FireRating >= 60`" at interactive speed across a million
rows.

### Element identity: two ids, never conflated

- `element_index` — positional, assigned at tessellation, the value the GPU
  kernel packs into a triangle and hands back per vertex. Meaningful only within
  one `model_version`.
- `ifc_guid` — survives model re-issues and is what Revit, Navisworks and BCF
  speak.

The device joins on the index because that is what its geometry carries; every
finding is stored against both. An element with no `ifc_guid` is reportable but
not addressable, and the app says so on load rather than after the walkthrough —
see `BIMModel.addressableFraction`.

### The metadata sidecar

USDZ preserves geometry and node names, and no properties. The tessellator writes
`<model>.elements.json` alongside it, keyed by the node name it emitted:

```json
{
  "modelVersionID": "R3",
  "unitScale": 0.001,
  "elements": [
    {
      "node": "IfcColumn_C-12_1aBc0De7F9gHiJkLmNoPqR",
      "ifcGuid": "1aBc0De7F9gHiJkLmNoPqR",
      "name": "UC 305x305x97",
      "ifcType": "IfcColumn",
      "category": "Structural Columns",
      "level": "Level 2",
      "mark": "C-12",
      "toleranceClass": "structural",
      "properties": { "LoadBearing": "true" }
    }
  ]
}
```

`modelVersionID` is checked against the geometry on load. Metadata from a
different revision would attribute deviations to the wrong elements, which is
worse than having none, so the mismatch is a load failure rather than a warning.

`unitScale` is metres per source unit — `0.001` for a millimetre export. The
sidecar overrides whatever the operator picked, because the exporter knows the
source units and the operator is guessing.

Without a sidecar the app falls back to parsing node names, and marks every
element non-addressable. A node name may *look* like it contains an IFC GUID;
that candidate is kept in `properties.nodeGuidCandidate` and never promoted to
`ifc_guid`. A guessed identifier files a defect against somebody else's column.

---

## "Live sync with Revit" — what is actually achievable

Revit is a desktop application with file checkout and no realtime API. Continuous
bidirectional sync with a phone on a construction site is not a thing that can be
built, and planning around it will burn a quarter.

What delivers the same value:

**Design → site.** A Revit add-in (or Speckle, or APS Model Derivative) publishes
a versioned snapshot on demand and fires a webhook. The import service ingests
it as a new `model_versions` row and tessellates. The device is told a newer
revision exists; it does not silently swap models mid-inspection, because a
finding is a statement about a specific revision.

**Site → design.** Findings return as **BCF 2.1/3.0** issues. The `markups`,
`markup_viewpoints`, `markup_comments` and `markup_elements` tables are shaped to
BCF deliberately, so an issue exports to Navisworks, Solibri or Revit with its
camera and component selection intact and no translation layer. `topic_guid` is
the BCF GUID and is how an external tool recognises the same issue on a later
round trip.

This is a publish/subscribe loop with a human decision at each end, which is what
the work actually is.

---

## Deviation runs in two places, on purpose

**On the device**, per frame, against the mesh chunks in view. This is what the
inspector acts on while standing in front of the problem. It is fast, partial,
and computed against whatever registration was current at that moment.

**On the server**, once, over the full registered point cloud against the full
IFC. This is the record. It is reproducible, it can be re-run when a new model
revision lands, and it does not depend on which order somebody walked the bay.

Both are stored: `element_inspections.computed_by` is `'device'` or `'server'`,
and the unique key admits one of each. The device figure is what the inspector
acted on; the server figure is what the report is signed against. Keeping both
is what lets a disagreement between them be noticed instead of reconciled away.

---

## Geo-referencing

`projects` carries the survey point, the base point offset and the true-north
rotation, plus an EPSG code. This is not optional detail. Shared coordinates are
the largest practical source of "the model is in the wrong place", and without
them a scan taken by one crew cannot be compared with one taken by another six
months later.

---

## Accuracy: what this system can and cannot claim

iPhone LiDAR is roughly 1–3 cm at close range, degrading with distance and with
how far the operator has walked. That budget bounds every number in the database.

**LOD 400 as-built is not reachable from iPhone LiDAR alone.** LOD 400 implies
fabrication-level tolerance — millimetres — and the sensor does not resolve it.
Two honest options:

1. Scope the deliverable to LOD 300/350 *verification*, which is what these
   tolerances genuinely support.
2. Add an E57/LAS import path from a terrestrial scanner and let the phone be the
   live-guidance and issue-capture tool, with the survey-grade cloud as the
   record. `point_clouds.format` already admits `e57`, `las` and `laz`.

Decide this before building the reporting layer; it changes what the reports are
allowed to say.

Three schema features exist to keep the numbers honest under that budget:

- **`status` has four values, not two.** An element nobody scanned is stored as
  `unverified`, never omitted. A missing row reads as a passing one, which is the
  single most dangerous way this system could be wrong.
- **`v_session_summary` reports `pass_rate` and `verified_fraction` together.** A
  100% pass rate over 12% of a building is not a passing building.
- **`drift_samples` is uploaded.** A session with three 40 mm corrections in it is
  not the same evidence as one with none, and the report should be able to say so.

---

## Upload contract

`POST /projects/{projectID}/scan-sessions`, body `SessionUpload`
(see [`SyncPayloads.swift`](../TwinzoScan/Sources/Sync/SyncPayloads.swift)).

Applied in a single transaction. Notes for the server implementer:

- **`clientChangeID` is the idempotency key.** Record it in `sync_receipts`
  before committing. A replay must return **409**, which the client treats as
  success — the work is stored and only the acknowledgement was lost. Returning
  an error there leaves the entry retrying forever.
- **`worldToModel` is row-major**, 16 doubles. simd is column-major; the
  transpose happens once, on the device.
- **Timestamps are ISO-8601 with milliseconds.** Two mesh chunks can be evaluated
  inside the same second and their order is part of the evidence.
- **Nulls are meaningful.** An `unverified` inspection sends `null` for every
  measurement, not `0`. Coercing those to zero on insert would turn "we did not
  look" into "we measured no deviation".
- **`400`/`422` must mean the payload is wrong**, and nothing else. The client
  treats those as non-retryable and stops; a validation error returned for a
  transient condition strands the inspection.
- Verify `modelVersionID` against the elements referenced. A mismatch means the
  device measured against different geometry than the server holds; reject it
  rather than importing findings against the wrong elements.
